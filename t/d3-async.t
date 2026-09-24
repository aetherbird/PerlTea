use strict;
use warnings;
use Test::More;
use Time::HiRes ();
use PerlTea;
use PerlTea::App::GitDash;

# D3 contract: refreshing the dashboard runs the git commands ASYNCHRONOUSLY so
# the UI never freezes. We assert three things:
#   1. Pressing 'r' returns a command (coderef) from update, NOT a blocking call.
#   2. Running that command yields a snapshot message that re-enters update and
#      updates the panes (loading/refreshing cleared, refresh count bumped).
#   3. Even with the deliberately-slow git delay engaged, the loop stays
#      responsive: a quit issued while a slow refresh is in flight is handled
#      promptly instead of blocking for the whole git call.

# 1. 'r' dispatches a command without blocking.
{
    my $dash = PerlTea::App::GitDash->new( repo => '.' );
    my ( $next, $cmd ) = $dash->update( { type => 'key', key => 'r' } );
    is( ref $cmd, 'CODE', "'r' returns an async command coderef" );
    ok( $next->{refreshing}, 'refreshing flag is set while the command runs' );
}

# Even with the slow-git delay forced on, update() itself must return at once —
# the delay lives in the command body (which the runtime forks), not in update.
{
    local $ENV{PERLTEA_GATE_SLOWGIT} = 1;
    my $dash = PerlTea::App::GitDash->new( repo => '.' );
    my $t0 = Time::HiRes::time();
    my ( $next, $cmd ) = $dash->update( { type => 'key', key => 'r' } );
    my $dt = Time::HiRes::time() - $t0;
    is( ref $cmd, 'CODE', 'slow-git refresh still returns a command' );
    cmp_ok( $dt, '<', 1.0,
        'update() returns immediately even when git is slow (no blocking)' );
}

# 2. The command produces a snapshot message that updates the panes.
{
    my $dash = PerlTea::App::GitDash->new( repo => '.' );
    my ( undef, $cmd ) = $dash->update( { type => 'key', key => 'r' } );
    my $msg = $cmd->();
    is( ref $msg, 'HASH', 'command returns a message hashref' );
    is( $msg->{type}, 'snapshot', 'the message is a snapshot message' );
    is( ref $msg->{data}, 'HASH', 'snapshot carries parsed data' );
    ok( exists $msg->{data}{branches}, 'snapshot has branches' );
    ok( exists $msg->{data}{status},   'snapshot has status' );
    ok( exists $msg->{data}{log},      'snapshot has log' );

    my $before = $dash->{refreshes};
    my ( $folded ) = $dash->update($msg);
    ok( !$folded->{loading},    'snapshot clears the loading flag' );
    ok( !$folded->{refreshing}, 'snapshot clears the refreshing flag' );
    cmp_ok( $folded->{refreshes}, '>', $before,
        'snapshot bumps the refresh count (panes updated)' );
}

# 3. Responsiveness under a slow refresh, exercised through the real event loop.
#    We drive run() over a real OS pipe (so the non-blocking select path engages,
#    exactly as the PTY gate does) with the slow-git delay forced on, and write a
#    'q' that arrives while the slow refresh command is still running. A
#    responsive loop quits well before the 2s git delay; a frozen one would block.
{
    local $ENV{PERLTEA_GATE_SLOWGIT} = 1;
    pipe( my $inr, my $inw ) or die "pipe: $!";
    my $out = '';
    open my $ofh, '>', \$out or die "out: $!";

    # 'r' kicks off the slow refresh, then 'q' must still be handled promptly.
    syswrite( $inw, "rq" );

    my $t0 = Time::HiRes::time();
    my $err = '';
    eval {
        local $SIG{ALRM} = sub { die "watchdog: loop blocked on slow git\n" };
        alarm 8;
        my $p = PerlTea->new(
            model => PerlTea::App::GitDash->new( repo => '.' ),
            in    => $inr,
            out   => $ofh,
        );
        $p->run;
        alarm 0;
        1;
    } or $err = $@;
    my $dt = Time::HiRes::time() - $t0;
    close $inw;
    close $inr;

    is( $err, '', 'slow-refresh run finishes without hanging' );
    cmp_ok( $dt, '<', 1.5,
        'loop quits promptly while a 2s git refresh is in flight (never froze)' );
}

done_testing;
