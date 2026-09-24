use strict;
use warnings;
use Test::More;
use PerlTea::Input;

# Gate G2 contract: the input decoder must turn the raw terminal byte stream into
# typed messages. This test exercises printable keys, control characters, CSI
# arrows/function keys, modifiers, SS3 sequences, and bracketed paste. The echo
# demo is additionally driven by the acceptance gate.

my $dec = PerlTea::Input->new;

# ── single-byte keys ─────────────────────────────────────────────────────────
is_deeply(
    [ $dec->feed('a') ],
    [ { type => 'key', key => 'a', rune => 'a', raw => 'a' } ],
    'printable letter'
);

is_deeply(
    [ $dec->feed(' ') ],
    [ { type => 'key', key => 'space', rune => ' ', raw => ' ' } ],
    'space is named, not empty'
);

is_deeply(
    [ $dec->feed("\t") ],
    [ { type => 'key', key => 'tab', rune => "\t", raw => "\t" } ],
    'tab byte'
);

is_deeply(
    [ $dec->feed("\r") ],
    [ { type => 'key', key => 'enter', rune => "\r", raw => "\r" } ],
    'carriage return -> enter'
);

is_deeply(
    [ $dec->feed("\e") ],
    [ { type => 'key', key => 'esc', rune => "\e", raw => "\e" } ],
    'lone escape'
);

is_deeply(
    [ $dec->feed("\x7f") ],
    [ { type => 'key', key => 'backspace', rune => "\x7f", raw => "\x7f" } ],
    'DEL -> backspace'
);

is_deeply(
    [ $dec->feed("\x01") ],
    [ { type => 'key', key => 'ctrl+a', rune => "\x01", raw => "\x01" } ],
    'Ctrl+A'
);

is_deeply(
    [ $dec->feed("\x1a") ],
    [ { type => 'key', key => 'ctrl+z', rune => "\x1a", raw => "\x1a" } ],
    'Ctrl+Z'
);

is_deeply(
    [ $dec->feed("\x00") ],
    [ { type => 'key', key => 'ctrl+space', rune => "\x00", raw => "\x00" } ],
    'NUL -> ctrl+space'
);

# ── multi-byte chunks split into separate messages ───────────────────────────
my @m = $dec->feed("ab\e[A");
is( scalar @m, 3, 'three messages in one chunk' );
is( $m[0]{key}, 'a',   'first chunk letter' );
is( $m[1]{key}, 'b',   'second chunk letter' );
is( $m[2]{key}, 'up',  'arrow decoded from same chunk' );

# ── CSI arrow keys ───────────────────────────────────────────────────────────
for my $pair (
    [ "\e[A", 'up' ],
    [ "\e[B", 'down' ],
    [ "\e[C", 'right' ],
    [ "\e[D", 'left' ],
) {
    my ( $seq, $name ) = @$pair;
    is_deeply(
        [ PerlTea::Input->new->feed($seq) ],
        [ { type => 'key', key => $name, rune => '', raw => $seq } ],
        "CSI $name"
    );
}

# ── CSI special keys ─────────────────────────────────────────────────────────
for my $pair (
    [ "\e[H",  'home' ],
    [ "\e[F",  'end' ],
    [ "\e[2~", 'insert' ],
    [ "\e[3~", 'delete' ],
    [ "\e[5~", 'pgup' ],
    [ "\e[6~", 'pgdown' ],
    [ "\e[Z",  'shift+tab' ],
) {
    my ( $seq, $name ) = @$pair;
    is_deeply(
        [ PerlTea::Input->new->feed($seq) ],
        [ { type => 'key', key => $name, rune => '', raw => $seq } ],
        "CSI $name"
    );
}

# ── function keys (tilde encoding) ───────────────────────────────────────────
for my $pair (
    [ "\e[11~", 'f1' ],
    [ "\e[12~", 'f2' ],
    [ "\e[13~", 'f3' ],
    [ "\e[14~", 'f4' ],
    [ "\e[15~", 'f5' ],
    [ "\e[17~", 'f6' ],
    [ "\e[18~", 'f7' ],
    [ "\e[19~", 'f8' ],
    [ "\e[20~", 'f9' ],
    [ "\e[21~", 'f10' ],
    [ "\e[23~", 'f11' ],
    [ "\e[24~", 'f12' ],
) {
    my ( $seq, $name ) = @$pair;
    is_deeply(
        [ PerlTea::Input->new->feed($seq) ],
        [ { type => 'key', key => $name, rune => '', raw => $seq } ],
        "function $name"
    );
}

# ── SS3 arrows + F1-F4 ───────────────────────────────────────────────────────
for my $pair (
    [ "\eOA", 'up' ],
    [ "\eOB", 'down' ],
    [ "\eOC", 'right' ],
    [ "\eOD", 'left' ],
    [ "\eOP", 'f1' ],
    [ "\eOQ", 'f2' ],
    [ "\eOR", 'f3' ],
    [ "\eOS", 'f4' ],
) {
    my ( $seq, $name ) = @$pair;
    is_deeply(
        [ PerlTea::Input->new->feed($seq) ],
        [ { type => 'key', key => $name, rune => '', raw => $seq } ],
        "SS3 $name"
    );
}

# ── modifiers ────────────────────────────────────────────────────────────────
is_deeply(
    [ PerlTea::Input->new->feed("\e[1;5A") ],
    [ { type => 'key', key => 'ctrl+up', rune => '', raw => "\e[1;5A" } ],
    'Ctrl+Up'
);

is_deeply(
    [ PerlTea::Input->new->feed("\e[1;2D") ],
    [ { type => 'key', key => 'shift+left', rune => '', raw => "\e[1;2D" } ],
    'Shift+Left'
);

is_deeply(
    [ PerlTea::Input->new->feed("\e[1;6B") ],
    [ { type => 'key', key => 'shift+ctrl+down', rune => '', raw => "\e[1;6B" } ],
    'Shift+Ctrl+Down'
);

# ── bracketed paste ──────────────────────────────────────────────────────────
is_deeply(
    [ PerlTea::Input->new->feed("\e[200~hello world\e[201~") ],
    [ { type => 'paste', text => 'hello world', raw => "\e[200~hello world\e[201~" } ],
    'bracketed paste in one chunk'
);

# Paste split across two feeds.
{
    my $p = PerlTea::Input->new;
    my @m1 = $p->feed("\e[200~part1");
    is( scalar @m1, 0, 'paste start yields no message yet' );
    my @m2 = $p->feed("-part2\e[201~after");
    is( scalar @m2, 6, 'paste end + five following single-byte keys' );
    is( $m2[0]{type}, 'paste',       'paste message type' );
    is( $m2[0]{text}, 'part1-part2', 'paste text concatenated' );
    is( $m2[1]{key},  'a',           'first key after paste' );
    is( $m2[5]{key},  'r',           'last key after paste' );
}

# ── alt+key sequences ────────────────────────────────────────────────────────
is_deeply(
    [ PerlTea::Input->new->feed("\ex") ],
    [ { type => 'key', key => 'alt+x', rune => 'x', raw => "\ex" } ],
    'Alt+x'
);

# ── incomplete sequences wait for more bytes ─────────────────────────────────
{
    my $p = PerlTea::Input->new;
    my @m1 = $p->feed("\e[");
    is( scalar @m1, 0, 'incomplete CSI waits' );
    my @m2 = $p->feed("A");
    is( scalar @m2, 1, 'completed CSI emits message' );
    is( $m2[0]{key}, 'up', 'completed CSI is up arrow' );
}

done_testing;
