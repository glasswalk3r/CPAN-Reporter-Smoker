package CPAN::Reporter::Smoker;
use 5.006;
use strict;
use warnings;
our $VERSION = '0.12'; 
$VERSION = eval $VERSION; ## no critic

use Carp;
use Config;
use CPAN; 
use CPAN::Tarzip;
use CPAN::HandleConfig;
use CPAN::Reporter::History;
use Compress::Zlib;
use File::Temp 0.20;
use File::Spec;
use File::Basename qw/basename/;
use Probe::Perl;
use Term::Title;

use Exporter;
our @ISA = 'Exporter';
our @EXPORT = qw/ start /; ## no critic Export

#--------------------------------------------------------------------------#
# globals
#--------------------------------------------------------------------------#

my $perl = Probe::Perl->find_perl_interpreter;
#my $tmp_dir = File::Temp->newdir( 'CPAN-Reporter-Smoker-XXXXXXX', 
#    DIR => File::Spec->tmpdir,
#    UNLINK => 0,
#);
my $tmp_dir = File::Temp::tempdir;

#--------------------------------------------------------------------------#
# start -- start automated smoking
#--------------------------------------------------------------------------#
my %spec = (
    clean_cache_after => { 
        default => 100, 
        is_valid => sub { /^\d+$/ },
    },
    restart_delay => { 
        default => 12 * 3600, # 12 hours
        is_valid => sub { /^\d+$/ },
    },
    set_term_title => { 
        default => 1,       
        is_valid => sub { /^[01]$/ },
    },
);
 
sub start {
    my %args = map { $_ => $spec{$_}{default} } keys %spec;
    croak "Invalid arguments to start(): must be key/value pairs"
        if @_ % 2;
    while ( @_ ) {
        my ($key, $value) = splice @_, 0, 2;
        local $_ = $value; # alias for validator
        croak "Invalid argument to start(): $key => $value"
            unless $spec{$key} && $spec{$key}{is_valid}->($value);
        $args{$key} = $value;
    }

    # Stop here if we're just testing
    return 1 if $ENV{PERL_CR_SMOKER_SHORTCUT};

    # Notify before CPAN messages start
    $CPAN::Frontend->mywarn( "Starting CPAN::Reporter::Smoker\n" );

    # Let things know we're running automated
    local $ENV{AUTOMATED_TESTING} = 1;

    # Always accept default prompts
    local $ENV{PERL_MM_USE_DEFAULT} = 1;

    # Load CPAN configuration
    my $init_cpan = 0;
    unless ( $init_cpan++ ) {
        CPAN::HandleConfig->load();
        CPAN::Shell::setup_output;
        CPAN::Index->reload;
        $CPAN::META->checklock(); # needed for cache scanning
    }

    # Win32 SIGINT propogates all the way to us, so trap it before we smoke
    # Must come *after* checklock() to override CPAN's $SIG{INT}
    local $SIG{INT} = \&_prompt_quit;

    # Master loop
    # loop counter will increment with each restart - useful for testing
    my $loop_counter = 0;

    # global cache of distros smoked to speed skips on restart
    my %seen = map { $_->{dist} => 1 } CPAN::Reporter::History::have_tested();

    SCAN_LOOP:
    while ( 1 ) {
        $loop_counter++;
        my $loop_start_time = time;

        # Get the list of distributions to process
        my $package = _get_module_index( 'modules/02packages.details.txt.gz' );
        my $find_ls = _get_module_index( 'indices/find-ls.gz' );
        CPAN::Index->reload;
        $CPAN::Frontend->mywarn( "Smoker: scanning and sorting index\n");

        my $dists = _parse_module_index( $package, $find_ls );

        $CPAN::Frontend->mywarn( "Smoker: found " . scalar @$dists . " distributions on CPAN\n");

        # Check if we need to manually reset test history during each dist loop 
        my $reset_string = q{};
        if ( $CPAN::Config->{build_dir_reuse} 
          && $CPAN::META->can('reset_tested') )
        {
          $reset_string = '$CPAN::META->reset_tested; '
        }

        # Clean cache on start and count dists tested to trigger cache cleanup
        _clean_cache();
        my $dists_tested = 0;

        # Start smoking
        DIST:
        for my $d ( 0 .. $#{$dists} ) {
            my $dist = CPAN::Shell->expandany($dists->[$d]);
            my $base = $dist->base_id;
            local $ENV{PERL_CR_SMOKER_CURRENT} = $base;
            my $count = sprintf('%d/%d', $d+1, scalar @$dists);
            if ( $seen{$base}++ ) {
                $CPAN::Frontend->mywarn( 
                    "Smoker: already tested $base [$count]\n");
                next DIST;
            }
            else {
                my $time = scalar localtime();
                my $msg = "$base [$count] at $time";
                if ( $args{set_term_title} ) {
                  Term::Title::set_titlebar( "Smoking $msg" );
                }
                $CPAN::Frontend->mywarn( "\nSmoker: testing $msg\n\n" );
                system($perl, "-MCPAN", "-e", 
                  "local \$CPAN::Config->{test_report} = 1; " 
                  . $reset_string . "test( '$dists->[$d]' )"
                );
                _prompt_quit( $? & 127 ) if ( $? & 127 );
                $dists_tested++;
            }
            if ( $dists_tested >= $args{clean_cache_after} ) {
              _clean_cache();
              $dists_tested = 0;
            }
            next SCAN_LOOP if time - $loop_start_time > $args{restart_delay};
        }
        last SCAN_LOOP if $ENV{PERL_CR_SMOKER_RUNONCE};
        # if here, we are out of distributions to test, so sleep
        my $delay = int( $args{restart_delay} - ( time - $loop_start_time ));
        if ( $delay > 0 ) {
          $CPAN::Frontend->mywarn( 
            "\nSmoker: Finished all available dists. Sleeping for $delay seconds.\n\n" 
          );
          sleep $delay ;
        }
    }

    CPAN::cleanup();
    return $loop_counter;
}

#--------------------------------------------------------------------------#
# private variables and functions
#--------------------------------------------------------------------------#

sub _clean_cache {
  # Possibly clean up cache if it exceeds defined size
  if ( $CPAN::META->{cachemgr} ) {
    $CPAN::META->{cachemgr}->scan_cache();
  }
  else {
    $CPAN::META->{cachemgr} = CPAN::CacheMgr->new(); # also scans cache
  }
}
        
sub _prompt_quit {
    my ($sig) = @_;
    # convert numeric to name
    if ( $sig =~ /\d+/ ) {
        my @signals = split q{ }, $Config{sig_name};
        $sig = $signals[$sig] || '???';
    }
    $CPAN::Frontend->myprint( 
        "\nStopped during $ENV{PERL_CR_SMOKER_CURRENT}.\n" 
    ) if defined $ENV{PERL_CR_SMOKER_CURRENT};
    $CPAN::Frontend->myprint(
        "\nCPAN testing halted on SIG$sig.  Continue (y/n)? [n]\n"
    );
    my $answer = <STDIN>;
    CPAN::cleanup(), exit 0 unless substr( lc($answer), 0, 1) eq 'y';
    return;
}

#--------------------------------------------------------------------------#
# _get_module_index
#
# download the 01modules index and return the local file name
#--------------------------------------------------------------------------#

sub _get_module_index {
    my ($remote_file) = @_;

    $CPAN::Frontend->mywarn( 
        "Smoker: getting $remote_file from CPAN\n");
    # CPAN.pm may not use aslocal if it's a file:// mirror
    my $aslocal_file = File::Spec->catfile( $tmp_dir, basename( $remote_file ));
    my $actual_local = CPAN::FTP->localize( $remote_file, $aslocal_file );
    if ( ! -r $actual_local ) {
        die "Couldn't get '$remote_file' from your CPAN mirror. Halting\n";
    }
    return $actual_local;
}

my $module_index_re = qr{
    ^\s href="\.\./authors/id/./../    # skip prelude 
    ([^"]+)                     # capture to next dquote mark
    .+? </a>                    # skip to end of hyperlink
    \s+                         # skip spaces
    \S+                         # skip size
    \s+                         # skip spaces
    (\S+)                       # capture day
    \s+                         # skip spaces
    (\S+)                       # capture month 
    \s+                         # skip spaces
    (\S+)                       # capture year
}xms; 

my %months = ( 
    Jan => '01', Feb => '02', Mar => '03', Apr => '04', May => '05',
    Jun => '06', Jul => '07', Aug => '08', Sep => '09', Oct => '10',
    Nov => '11', Dec => '12'
);

# standard regexes
# note on archive suffixes -- .pm.gz shows up in 02packagesf
my %re = (
    bundle => qr{^Bundle::},
    mod_perl => qr{/mod_perl},
    perls => qr{(?:
		  /(?:emb|syb|bio)?perl-\d 
		| /(?:parrot|ponie|kurila|Perl6-Pugs)-\d 
		| /perl-?5\.004 
		| /perl_mlb\.zip 
    )}xi,
    archive => qr{\.(?:tar\.(?:bz2|gz|Z)|t(?:gz|bz)|zip|pm.gz)$}i,
    target_dir => qr{
        ^(?:
            modules/by-module/[^/]+/./../ | 
            modules/by-module/[^/]+/ | 
            modules/by-category/[^/]+/[^/]+/./../ | 
            modules/by-category/[^/]+/[^/]+/ | 
            authors/id/./../ 
        )
    }x,
    leading_initials => qr{(.)/\1./},
);

# match version and suffix
$re{version_suffix} = qr{([-._]v?[0-9].*)($re{archive})};

# split into "AUTHOR/Name" and "Version"
$re{split_them} = qr{^(.+?)$re{version_suffix}$};

# matches "AUTHOR/tarball.suffix" or AUTHOR/modules/tarball.suffix
# and not other "AUTHOR/subdir/whatever"

# Just get AUTHOR/tarball.suffix from whatever file name is passed in
sub _get_base_id { 
    my $file = shift;
    my $base_id = $file;
    $base_id =~ s{$re{target_dir}}{};
    return $base_id;
}

sub _base_name {
    my ($base_id) = @_;
    my $base_file = basename $base_id;
    my ($base_name, $base_version) = $base_file =~ $re{split_them};
    return $base_name;
}

#--------------------------------------------------------------------------#
# _parse_module_index
#
# parse index and return array_ref of distributions in reverse date order
#--------------------------------------------------------------------------#-

sub _parse_module_index {
    my ( $packages, $file_ls ) = @_;

	# first walk the packages list
    # and build an index

    my (%valid_bases, %valid_distros, %mirror);
    my (%latest, %latest_dev);

    my $gz = Compress::Zlib::gzopen($packages, "rb")
        or die "Cannot open package list: $Compress::Zlib::gzerrno";

    my $inheader = 1;
    while ($gz->gzreadline($_) > 0) {
        if ($inheader) {
            $inheader = 0 unless /\S/;
            next;
        }

        my ($module, $version, $path) = split;
        
        my $base_id = _get_base_id("authors/id/$path");

        # skip all perl-like distros
        next if $base_id =~ $re{perls};

        # skip mod_perl environment
        next if $base_id =~ $re{mod_perl};
        
        # skip all bundles
        next if $module =~ $re{bundle};

        $valid_distros{$base_id}++;
        my $base_name = _base_name( $base_id );
        if ($base_name) {
            $latest{$base_name} = {
                datetime => 0,
                base_id => $base_id
            };
        }
    }

    # next walk the find-ls file
    local *FH;
    tie *FH, 'CPAN::Tarzip', $file_ls;

    while ( defined ( my $line = <FH> ) ) {
        my %stat;
        @stat{qw/inode blocks perms links owner group size datetime name linkname/}
            = split q{ }, $line;
        
        unless ($stat{name} && $stat{perms} && $stat{datetime}) {
            next;
        }
        # skip directories, symlinks and things that aren't a tarball
        next if $stat{perms} eq "l" || substr($stat{perms},0,1) eq "d";
        next unless $stat{name} =~ $re{target_dir};
        next unless $stat{name} =~ $re{archive};

        # skip if not AUTHOR/tarball 
        # skip perls
        my $base_id = _get_base_id($stat{name});
        next unless $base_id; 
        
        next if $base_id =~ $re{perls};

        my $base_name = _base_name( $base_id );

        # if $base_id matches 02packages, then it is the latest version
        # and we definitely want it; also update datetime from the initial
        # assumption of 0
        if ( $valid_distros{$base_id} ) {
            $mirror{$base_id} = $stat{datetime};
            next unless $base_name;
            if ( $stat{datetime} > $latest{$base_name}{datetime} ) {
                $latest{$base_name} = { 
                    datetime => $stat{datetime}, 
                    base_id => $base_id
                };
            }
        }
        # if not in the packages file, we only want it if it resembles 
        # something in the package file and we only the most recent one
        else {
            # skip if couldn't parse out the name without version number
            next unless defined $base_name;

            # skip unless there's a matching base from the packages file
            next unless $latest{$base_name};

            # keep only the latest
            $latest_dev{$base_name} ||= { datetime => 0 };
            if ( $stat{datetime} > $latest_dev{$base_name}{datetime} ) {
                $latest_dev{$base_name} = { 
                    datetime => $stat{datetime}, 
                    base_id => $base_id
                };
            }
        }
    }

    # pick up anything from packages that wasn't found find-ls
    for my $name ( keys %latest ) {
        my $base_id = $latest{$name}{base_id};
        $mirror{$base_id} = $latest{$name}{datetime} unless $mirror{$base_id};
    }
          
    # for dev versions, it must be newer than the latest version of
    # the same base name from the packages file

    for my $name ( keys %latest_dev ) {
        if ( ! $latest{$name} ) {
            next;
        }
        next if $latest{$name}{datetime} > $latest_dev{$name}{datetime};
        $mirror{ $latest_dev{$name}{base_id} } = $latest_dev{$name}{datetime} 
    }

    return [ sort { $mirror{$b} <=> $mirror{$a} } keys %mirror ];
}

1; #modules must return true

__END__

#--------------------------------------------------------------------------#
# pod documentation 
#--------------------------------------------------------------------------#

=begin wikidoc

= NAME

CPAN::Reporter::Smoker - Turnkey CPAN Testers smoking

= VERSION

This documentation describes version %%VERSION%%.

= SYNOPSIS

    $ perl -MCPAN::Reporter::Smoker -e start

= DESCRIPTION

Rudimentary smoke tester for CPAN Testers, built upon [CPAN::Reporter].  Use
at your own risk.  It requires a recent version of CPAN::Reporter to run.

Currently, CPAN::Reporter::Smoker requires zero independent configuration;
instead it uses configuration settings from CPAN.pm and CPAN::Reporter.

Once started, it retrieves a list of distributions from the configured CPAN
mirror and begins testing them in reverse order of upload.  It will skip any
distribution which has already had a report sent by CPAN::Reporter.  

Features (or bugs, depending on your point of view):

* No configuration needed
* Tests each distribution as a separate CPAN process -- each distribution
has prerequisites like build_requires satisfied from scratch
* Automatically checks for new distributions every twelve hours or as
otherwise specified
* Continues until interrupted with CTRL-C

Current limitations:

* Does not check any skip files before handing off to CPAN to test -- use 
CPAN.pm "distroprefs" instead
* Does not attempt to retest distributions that had reports discarded because 
of prerequisites that could not be satisfied

== WARNING -- smoke testing is risky

Smoke testing will download and run programs that other people have uploaded to
CPAN.  These programs could do *anything* to your system, including deleting
everything on it.  Do not run CPAN::Reporter::Smoker unless you are prepared to
take these risks.  

= HINTS

== Selection of distributions to test

Only the most recently uploaded developer and normal releases will be
tested, and only if the developer release is newer than the regular release
indexed by PAUSE.  

For example, if Foo-Bar-0.01, Foo-Bar-0.02, Foo-Bar-0.03_01 and Foo-Bar-0.03_02
are on CPAN, only Foo-Bar-0.02 and Foo-Bar-0.03_02 will be tested, and in
reverse order of when they were uploaded.  Once Foo-Bar-0.04 is released and
indexed, Foo-Bar-0.03_02 will not longer be tested.

To avoid testing script or other tarballs, developer distributions included
must have a base distribution name that resembles a distribution tarball
already indexed by PAUSE.  If the first upload of distribution to PAUSE is a
developer release -- Baz-Bam-0.00_01.tar.gz -- it will not be tested as there
is no indexed Baz-Bam appearing in CPAN's 02packages.details.txt file.  

Unauthorized tarballs are treated like developer releases and will be tested
if they resemble an indexed distribution and are newer than the indexed
tarball.

Perl, parrot, kurila, Pugs and similar distributions will not be tested.  The
skip list is based on CPAN::Mini and matches as follows:
    
    qr{(?:
		  /(?:emb|syb|bio)?perl-\d 
		| /(?:parrot|ponie|kurila|Perl6-Pugs)-\d 
		| /perl-?5\.004 
		| /perl_mlb\.zip 
    )}xi,

Bundles and mod_perl distributions will also not be tested, though mod_perl is
likely to be requested as a dependency by many modules.  See the next section
for how to tell CPAN.pm not to test certain dependencies.

== Skipping additional distributions

If certain distributions hang, crash or otherwise cause trouble, you can use
CPAN's "distroprefs" system to disable them.  If a distribution is disabled, it
won't be built or tested.  If a distribution's dependency is disabled, a 
failing test is just discarded.

The first step is configuring a directory for distroprefs files:

    $ cpan
    cpan> o conf init prefs_dir
    cpan> o conf commit

Next, ensure that either the [YAML] or [YAML::Syck] module is installed.  
(YAML::Syck is faster).  Then create a file in the {prefs_dir} directory
to hold the list of distributions to disable, e.g. call it {disabled.yml}

In that file, you can add blocks of YAML code to disable distributions.  The
match criteria "distribution" is a regex that matches against the canonical
name of a distribution, e.g. {AUTHOR/Foo-Bar-3.14.tar.gz}.

Here is a sample file to show you some syntax (don't actually use these,
though):

    ---
    comment: "Tests take too long"
    match:
        distribution: "^DAGOLDEN/CPAN-Reporter-\d"
    disabled: 1
    ---
    comment: "Skip Win32 distributions"
    match:
        distribution: "/Win32"
    disabled: 1
    ---
    comment: "Skip distributions by Andy Lester"
    match:
        distribution: "^PETDANCE"
    disabled: 1

Please note that disabling distributions like this will also disable them
for normal, non-smoke usage of CPAN.pm.

One distribution that I would recommend either installing up front or else
disabling with distroprefs is mod_perl, as it is a common requirement for many
Apache:: modules but does not (easily) build and test under automation.

    ---
    comment: "Don't build mod_perl if required by some other module"
    match:
        distribution: "/mod_perl-\d"
    disabled: 1

Distroprefs are more powerful than this -- they can be used to automate
responses to prompts in distributions, set environment variables, specify
additional dependencies and so on.  Read the docs for CPAN.pm for more and
look in the "distroprefs" directory in the CPAN distribution tarball for
examples.

== Turning off reports to authors 

CPAN::Reporter (since 1.08) supports skipfiles to avoid copying certain authors
on failing reports or to prevent sending a report at all to CPAN Testers.  Use
these to stop sending reports if someone complains.  See
[CPAN::Reporter::Config] for more details.

Note -- these do not stop CPAN::Reporter::Smoker from processing distributions.
They only change whether reports are sent and to whom.

If you don't want to copy authors at all, set the "cc_author" option
to "no" in your CPAN::Reporter config file.

    cc_author = no

== Using a local CPAN::Mini mirror

Because distributions must be retrieved from a CPAN mirror, the smoker may
cause heavy network load and will reptitively download common build 
prerequisites.  

An alternative is to use [CPAN::Mini] to create a local CPAN mirror and to
point CPAN's {urllist} to the local mirror.

    $ cpan
    cpan> o conf urllist unshift file:///path/to/minicpan
    cpan> o conf commit

However, CPAN::Reporter::Smoker needs the {find-ls.gz} file, which
CPAN::Mini does not mirror by default.  Add it to a .minicpanrc file in your
home directory to include it in your local CPAN mirror.

    also_mirror: indices/find-ls.gz

Note that CPAN::Mini does not mirror developer versions.  Therefore, a
live, network CPAN Mirror will be needed in the urllist to retrieve these.

Note that CPAN requires the LWP module to be installed to use a local CPAN
mirror.

Alternatively, you might experiment with the alpha-quality release of
[CPAN::Mini::Devel], which subclasses CPAN::Mini to retrieve developer
distributions (and find-ls.gz) using the same logic as 
CPAN::Reporter::Smoker.

== Timing out hanging tests

CPAN::Reporter (since 1.08) supports a 'command_timeout' configuration option.
Set this option in the CPAN::Reporter configuration file to time out tests that
hang up or get stuck at a prompt.  Set it to a high-value to avoid timing out a
lengthy tests that are still running  -- 1000 or more seconds is probably
enough.

Warning -- on Win32, terminating processes via the command_timeout is equivalent to
SIGKILL and could cause system instability or later deadlocks

This option is still considered experimental.

== Avoiding repetitive prerequisite testing

Because CPAN::Reporter::Smoker satisfies all requirements from scratch, common
dependencies (e.g. Class::Accessor) will be unpacked, built and tested 
repeatedly.

As of version 1.92_56, CPAN supports the {trust_test_report_history} config
option.  When set, CPAN will check the last test report for a distribution.
If one is found, the results of that test are used instead of running tests
again.

    $ cpan
    cpan> o conf init trust_test_report_history
    cpan> o conf commit

== Avoiding repetitive prerequisite builds (EXPERIMENTAL)

CPAN has a {build_dir_reuse} config option.  When set (and if a YAML module is
installed and configured), CPAN will attempt to make build directories
persistent.  This has the potential to save substantial time and space during
smoke testing.  CPAN::Reporter::Smoker will recognize if this option is set
and make adjustments to the test process to keep PERL5LIB from growing
uncontrollably as the number of persistent directories increases.

*NOTE:* Support for {build_dir_reuse} is highly experimental. Wait for at least
CPAN version 1.92_62 before trying this option.

    $ cpan
    cpan> o conf init build_dir_reuse
    cpan> o conf commit

== Stopping early if a prerequisite fails

Normally, CPAN.pm continues testing a distribution even if a prequisite fails
to build or fails testing.  Some distributions may pass their tests even
without a listed prerequisite, but most just fail (and CPAN::Reporter discards
failures if prerequisites are not met).

As of version 1.92_57, CPAN supports the {halt_on_failure} config option.
When set, a prerequisite failure stops further processing.

    $ cpan
    cpan> o conf init halt_on_failure
    cpan> o conf commit

However, a disadvantage of halting early is that no DISCARD grade is 
recorded in the history.  The next time CPAN::Reporter::Smoker runs, the
distribution will be tested again from scratch.  It may be better to let all
prerequisites finish so the distribution can fail its test and be flagged
with DISCARD so it will be skipped in the future.

== CPAN cache bloat

CPAN will use a lot of scratch space to download, build and test modules.  Use
CPAN's built-in cache management configuration to let it purge the cache
periodically if you don't want to do this manually.  When configured, the cache
will be purged on start and after a certain number of distributions have
been tested as determined by the {clean_cache_after} option for the 
{start()} function. 

    $ cpan
    cpan> o conf init build_cache scan_cache
    cpan> o conf commit

== CPAN verbosity

Recent versions of CPAN are verbose by default, but include some lesser
known configuration settings to minimize this for untarring distributions and
for loading support modules.  Setting the verbosity for these to 'none' will
minimize some of the clutter to the screen as distributions are tested.

    $ cpan
    cpan> o conf init /verbosity/
    cpan> o conf commit

== Test::Reporter timeouts and MAILDOMAIN

On some systems (e.g. Win32), Test::Reporter may take a long time to determine
the origin domain for mail.  Set the MAILDOMAIN environment variable instead to
avoid this delay.

= USAGE

== {start()}

Starts smoke testing using defaults already in CPAN::Config and
CPAN::Reporter's .cpanreporter directory.  Runs until all distributions are
tested or the process is halted with CTRL-C or otherwise killed.

{start()} supports several optional arguments:

* {clean_cache_after} -- number of distributions that will be tested 
before checking to see if the CPAN build cache needs to be cleaned up 
(not including any prerequisites tested); must be a positive integer;
defaults to 100
* {restart_delay} -- number of seconds that must elapse before restarting 
smoke testing; this will reload indices to search for new distributions
and restart testing from the most recent distribution; must be a positive
integer; defaults to 43200 seconds (12 hours)
* {set_term_title} -- toggle for whether the terminal titlebar will be
updated with the distribution being smoke tested and the starting time
of the test; helps determine if a test is hung and which distribution
might be responsible; valid values are 0 or 1; defaults to 1

= ENVIRONMENT

Automatically sets the following environment variables to true values 
while running:

* {AUTOMATED_TESTING} -- signal that tests are being run by an automated
smoke testing program (i.e. don't expect interactivity)
* {PERL_MM_USE_DEFAULT} -- accept [ExtUtils::MakeMaker] prompt() defaults

The following environment variables, if set, will modify the behavior of
CPAN::Reporter::Smoker.  Generally, they are only required during the
testing of CPAN::Reporter::Smoker

* {PERL_CR_SMOKER_RUNONCE} -- if true, {start()} will exit after all
distributions are tested instead of sleeping for the {restart_delay}
and then continuing
* {PERL_CR_SMOKER_SHORTCUT} -- if true, {start()} will process arguments (if 
any) but will return before starting smoke testing; used for testing argument
handling by {start()}

= BUGS

Please report any bugs or feature using the CPAN Request Tracker.  
Bugs can be submitted through the web interface at 
[http://rt.cpan.org/Dist/Display.html?Queue=CPAN-Reporter-Smoker]

When submitting a bug or request, please include a test-file or a patch to an
existing test-file that illustrates the bug or desired feature.

= SEE ALSO

* [CPAN]
* [CPAN::Reporter]
* [CPAN::Testers]
* [CPAN::Mini]
* [CPAN::Mini::Devel]

= AUTHOR

David A. Golden (DAGOLDEN)

= COPYRIGHT AND LICENSE

Copyright (c) 2008 by David A. Golden

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at 
[http://www.apache.org/licenses/LICENSE-2.0]

Files produced as output though the use of this software, shall not be
considered Derivative Works, but shall be considered the original work of the
Licensor.

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=end wikidoc

=cut
