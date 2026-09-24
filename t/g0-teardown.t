use strict;
use warnings;
use Test::More;
use PerlTea;

# G0 contract: the terminal is restored on EVERY exit path. We can't get a real tty
# here, so we drive run() with in-memory handles. Raw-mode termios is skipped when
# the input isn't a tty, but the *visible* restore sequences (show-cursor, leave
# alt-screen) are always written to the output handle — that is what we assert.
#
# Why this matters: a TUI that exits (cleanly OR by dying) without showing the
# cursor and leaving the alt-screen leaves the user's terminal wedged. This test
# pins that the show-cursor sequence ESC[?25h is emitted on both the normal-quit
# and the uncaught-die paths — the same marker the acceptance gate greps for.

my $SHOW_CUR = "\e[?25h";
my $LEAVE_ALT = "\e[?1049l";
my $ENTER_ALT = "\e[?1049h";

# A tiny model: 'q' quits, 'p' dies, anything else counts.
{
    package TModel;
    sub new    { bless { n => 0 }, shift }
    sub init   { undef }
    sub update {
        my ( $s, $msg ) = @_;
        my $k = $msg->{key} // '';
        return ( PerlTea->quit, undef ) if $k eq 'q';
        die "boom\n" if $k eq 'p';
        $s->{n}++;
        return ( $s, undef );
    }
    sub view { my $s = shift; "n=$s->{n}\r\n" }
}

# Helper: run a model over a scripted key string, return ($output, $error, $final).
sub drive {
    my ($keys) = @_;
    open my $in,  '<', \$keys      or die "in: $!";
    my $out = '';
    open my $ofh, '>', \$out       or die "out: $!";
    my $p = PerlTea->new(
        model      => TModel->new,
        in         => $in,
        out        => $ofh,
        alt_screen => 1,
    );
    my $final = eval { $p->run };
    my $err = $@;
    close $ofh;
    return ( $out, $err, $final );
}

# 1. Normal quit: a couple of counts then 'q'. Terminal restored, no error.
{
    my ( $out, $err, $final ) = drive("aaq");
    is( $err, '', 'normal quit does not die' );
    isa_ok( $final, 'TModel', 'run() returns the final model on quit' );
    is( $final->{n}, 2, 'two non-quit keys counted before quit' );
    like( $out, qr/\Q$ENTER_ALT\E/, 'entered the alternate screen' );
    like( $out, qr/\Q$SHOW_CUR\E/,  'cursor restored on normal quit' );
    like( $out, qr/\Q$LEAVE_ALT\E/, 'left the alternate screen on normal quit' );
}

# 2. End-of-input (no quit key) also ends the loop and restores the terminal.
{
    my ( $out, $err, $final ) = drive("aa");
    is( $err, '', 'EOF ends the loop without dying' );
    like( $out, qr/\Q$SHOW_CUR\E/, 'cursor restored on end-of-input' );
}

# 3. Uncaught die ('p'): the terminal is STILL restored, and the error re-throws so
#    the process would exit non-zero.
{
    my ( $out, $err, $final ) = drive("p");
    like( $err, qr/boom/, 'uncaught die propagates out of run()' );
    like( $out, qr/\Q$SHOW_CUR\E/,  'cursor restored even on an uncaught die' );
    like( $out, qr/\Q$LEAVE_ALT\E/, 'left the alternate screen on an uncaught die' );
}

# 4. Teardown is idempotent: calling the restore twice emits the sequence once.
{
    open my $in, '<', \( my $k = 'q' ) or die;
    my $out = '';
    open my $ofh, '>', \$out or die;
    my $p = PerlTea->new( model => TModel->new, in => $in, out => $ofh, alt_screen => 1 );
    $p->run;
    my $before = $out;
    $p->_leave_raw;    # second call must be a no-op
    is( $out, $before, 'restore is idempotent (no duplicate teardown output)' );
}

done_testing;
