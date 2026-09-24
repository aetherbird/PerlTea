use strict;
use warnings;
use Test::More;
use PerlTea;

# G3 contract: commands run asynchronously (forked) and post a message back into
# update; subscriptions feed timed messages; the loop NEVER blocks while either is
# in flight. We drive run() over a real OS pipe as the input handle (so the
# non-blocking select loop engages — an in-memory handle would not), but never
# write to it: each model quits itself once it has seen what the test is asserting.
# A watchdog alarm turns any "loop blocked forever" bug into a visible failure
# instead of a hang.

# Run a model under run() with a real (but silent) pipe for input, under a timeout.
sub run_model {
    my ( $model, $timeout ) = @_;
    pipe( my $inr, my $inw ) or die "pipe: $!";
    my $out = '';
    open my $ofh, '>', \$out or die "out: $!";

    my $final = eval {
        local $SIG{ALRM} = sub { die "watchdog: loop did not finish (blocked?)\n" };
        alarm( $timeout || 10 );
        my $p = PerlTea->new( model => $model, in => $inr, out => $ofh );
        my $f = $p->run;
        alarm 0;
        $f;
    };
    my $err = $@;
    close $inw;
    close $inr;
    return ( $final, $err );
}

# 1. A command (returned from init) dispatches asynchronously and its returned
#    message re-enters update. The model quits the moment it receives it.
{
    package CmdModel;
    sub new { bless { got => undef }, shift }
    sub init { return sub { return { type => 'cmddone', n => 7 } } }
    sub update {
        my ( $s, $msg ) = @_;
        if ( ( $msg->{type} // '' ) eq 'cmddone' ) {
            $s->{got} = $msg->{n};
            return ( PerlTea->quit, undef );
        }
        return ( $s, undef );
    }
    sub view { "got=" . ( $_[0]->{got} // '-' ) . "\n" }
}
{
    my ( $final, $err ) = run_model( CmdModel->new );
    is( $err, '', 'command round-trip finishes without error/hang' );
    is( ref $final && $final->{got}, 7,
        'a command dispatched and its message re-entered update' );
}

# 2. A subscription fires repeatedly on its timer and feeds messages into update
#    with no input at all.
{
    package SubModel;
    sub new { bless { ticks => 0 }, shift }
    sub subscriptions {
        return [ { every => 0.05, msg => sub { return { type => 'tick' } } } ];
    }
    sub update {
        my ( $s, $msg ) = @_;
        if ( ( $msg->{type} // '' ) eq 'tick' ) {
            $s->{ticks}++;
            return ( PerlTea->quit, undef ) if $s->{ticks} >= 3;
        }
        return ( $s, undef );
    }
    sub view { "ticks=$_[0]->{ticks}\n" }
}
{
    my ( $final, $err ) = run_model( SubModel->new );
    is( $err, '', 'subscription loop finishes without error/hang' );
    ok( ref $final && $final->{ticks} >= 3,
        'a subscription fed >=3 timed messages into update' );
}

# 3. The loop does not block on a slow command: a background task sleeps ~0.3s
#    while a fast (0.03s) clock subscription keeps ticking. If the loop blocked on
#    the command, the tick count would be ~0; we require it kept ticking.
{
    package SlowModel;
    sub new { bless { ticks => 0, done => 0 }, shift }
    sub init {
        return sub {
            select( undef, undef, undef, 0.3 );
            return { type => 'taskdone' };
        };
    }
    sub subscriptions {
        return [ { every => 0.03, msg => sub { return { type => 'tick' } } } ];
    }
    sub update {
        my ( $s, $msg ) = @_;
        my $t = $msg->{type} // '';
        if ( $t eq 'tick' ) { $s->{ticks}++ }
        elsif ( $t eq 'taskdone' ) {
            $s->{done} = 1;
            return ( PerlTea->quit, undef );
        }
        return ( $s, undef );
    }
    sub view { "x\n" }
}
{
    my ( $final, $err ) = run_model( SlowModel->new );
    is( $err, '', 'slow-command run finishes without error/hang' );
    ok( ref $final && $final->{done},
        'the background task completed and posted its message' );
    cmp_ok( ref $final ? $final->{ticks} : 0, '>=', 3,
        'the clock kept ticking while the slow task ran (loop never blocked)' );
}

done_testing;
