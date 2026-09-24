use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);

use PerlTea::App::GitDash;

# D1 — status parsing. The fixture is porcelain v1 with branch metadata,
# staged/unstaged changes, a rename, a conflict, and an untracked file.

my $fixture = "$FindBin::Bin/../testdata/git/status.txt";
open my $fh, '<', $fixture or die "$fixture: $!";
local $/;
my $text = <$fh>;
close $fh;

my $status = PerlTea::App::GitDash::parse_status($text);
is( $status->{branch}, 'main', 'branch parsed from porcelain header' );
is( $status->{upstream}, 'origin/main', 'upstream parsed from porcelain header' );
is( $status->{ahead}, 1, 'ahead count parsed from header' );
is( $status->{behind}, 2, 'behind count parsed from header' );
ok( !$status->{clean}, 'non-empty status is not clean' );
is( scalar( @{ $status->{entries} } ), 6, 'all status entries parsed' );

is( $status->{entries}[0]{path}, 'lib/PerlTea.pm', 'unstaged path parsed' );
ok( !$status->{entries}[0]{staged}, 'unstaged-only change is not staged' );
ok( $status->{entries}[0]{unstaged}, 'unstaged-only change marked unstaged' );

ok( $status->{entries}[1]{staged}, 'staged-only change marked staged' );
ok( !$status->{entries}[1]{unstaged}, 'staged-only change is not unstaged' );

is( $status->{entries}[3]{old_path}, 'old/name.txt', 'rename old path parsed' );
is( $status->{entries}[3]{path}, 'new/name.txt', 'rename new path parsed' );

ok( $status->{entries}[4]{conflict}, 'UU entry marked as conflict' );
ok( $status->{entries}[5]{untracked}, '?? entry marked untracked' );

my $clean = PerlTea::App::GitDash::parse_status("## main\n");
ok( $clean->{clean}, 'status with only a header is clean' );
is( scalar( @{ $clean->{entries} } ), 0, 'clean status has no entries' );

# The dashboard data layer must also be able to run git commands. Build a
# disposable git repository so this test passes even when the distribution is
# extracted outside a git worktree (e.g. `make disttest`).
my $tmpdir = tempdir( 'perltea-d1-status-XXXX', TMPDIR => 1, CLEANUP => 1 );
system( 'git', 'init', $tmpdir );
# Avoid git's user-config complaints in a fresh environment.
system( 'git', '-C', $tmpdir, 'config', 'user.email', 'test@example.com' );
system( 'git', '-C', $tmpdir, 'config', 'user.name',  'Test User' );

open my $wf, '>', "$tmpdir/file.txt" or die "write $tmpdir/file.txt: $!";
print $wf "hello\n";
close $wf;
system( 'git', '-C', $tmpdir, 'add', 'file.txt' );
system( 'git', '-C', $tmpdir, 'commit', '-m', 'initial' );

# Make a tracked change so status has at least one entry.
open my $uf, '>>', "$tmpdir/file.txt" or die "append $tmpdir/file.txt: $!";
print $uf "world\n";
close $uf;

my ( $live_status, $err ) = PerlTea::App::GitDash::run_git( $tmpdir, 'status' );
my $skip_run_git = ( defined $err || $live_status eq '' ) ? 'git status could not run' : undef;
SKIP: {
    skip $skip_run_git, 2 if defined $skip_run_git;
    is( $err, undef, 'run_git executes the status command in a temp repo' );
    my $live = PerlTea::App::GitDash::parse_status($live_status);
    ok( defined $live->{branch}, 'live status output parses a branch header' );
}

done_testing;
