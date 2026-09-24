#!/usr/bin/env perl
# G1 (extended) — East-Asian-aware display width.
#
# A terminal cell is one column, but a Unicode character is not always one cell:
# CJK / fullwidth glyphs take TWO columns, combining marks and zero-width
# characters take ZERO. If the renderer counts characters with length() it
# mis-aligns any wide or zero-width text. PerlTea::Width is the single place that
# decides column counts; this test pins the contract (wide=2, combining=0,
# normal=1) and proves the renderer lays a wide glyph across two cells so the
# buffer column index keeps matching the real terminal column.
use strict;
use warnings;
use utf8;

use Test::More;

use PerlTea::Width qw(char_width display_width truncate_to_width);
use PerlTea::Renderer;

# ── char_width: the three width classes ──────────────────────────────────────

# Normal runes are one column.
is( char_width('a'),          1, 'ASCII letter is 1 cell' );
is( char_width(' '),          1, 'space is 1 cell' );
is( char_width("\x{00E9}"),   1, 'precomposed e-acute is 1 cell' );    # é
is( char_width("\x{20AC}"),   1, 'euro sign (ambiguous) is 1 cell' );  # €
is( char_width("\x{2500}"),   1, 'box-drawing U+2500 is 1 cell' );     # horizontal rule

# East Asian Wide / Fullwidth glyphs are two columns.
is( char_width("\x{4E16}"),   2, 'CJK U+4E16 is 2 cells' );
is( char_width("\x{754C}"),   2, 'CJK U+754C is 2 cells' );
is( char_width("\x{3042}"),   2, 'Hiragana U+3042 is 2 cells' );
is( char_width("\x{FF21}"),   2, 'Fullwidth A U+FF21 is 2 cells' );
is( char_width("\x{1F600}"),  2, 'emoji U+1F600 is 2 cells' );

# Combining marks, zero-width characters, and controls are zero columns.
is( char_width("\x{0301}"),   0, 'combining acute accent is 0 cells' );
is( char_width("\x{0308}"),   0, 'combining diaeresis is 0 cells' );
is( char_width("\x{200B}"),   0, 'zero-width space is 0 cells' );
is( char_width("\x{200D}"),   0, 'zero-width joiner is 0 cells' );
is( char_width("\x{0000}"),   0, 'NUL is 0 cells' );
is( char_width("\t"),         0, 'control char (TAB) is 0 cells' );
is( char_width(''),           0, 'empty string is 0 cells' );

# ── display_width: summed, ANSI-stripped ─────────────────────────────────────

is( display_width('hello'),               5,  'plain ASCII width' );
is( display_width("\x{4E16}\x{754C}"),     4,  'two wide glyphs = 4 columns' );
is( display_width("a\x{4E16}b"),           4,  'mixed narrow+wide width' );
is( display_width("e\x{0301}"),            1,  'base + combining mark = 1 column' );
is( display_width("\e[1;31mx\e[0m"),       1,  'SGR escapes are not columns' );
is( display_width("\e[1m\x{4E16}\e[0m"),   2,  'styled wide glyph is still 2 columns' );
is( display_width(undef),                  0,  'undef is width 0' );

# A precomposed accented word and its combining-sequence form occupy the SAME
# number of columns — the whole point of zero-width combining handling.
is(
    display_width("café"),
    display_width("cafe\x{0301}"),
    'precomposed and decomposed forms have equal display width'
);

# ── truncate_to_width: respects column budget, never splits a wide glyph ──────

is( truncate_to_width("hello", 3), "hel", 'narrow truncation by column' );
is( truncate_to_width("\x{4E16}\x{754C}", 2), "\x{4E16}",
    'a wide glyph that would overflow the budget is dropped whole, not split' );
is( display_width( truncate_to_width("\x{4E16}\x{754C}\x{4E16}", 3) ), 2,
    'truncation never exceeds the column budget' );

# ── the renderer reaches the same function and aligns wide text ──────────────

is( PerlTea::Renderer::display_width("\x{4E16}x"), 3,
    'renderer exposes the display-width function' );

# A wide glyph followed by text: the renderer must place the wide glyph in one
# cell and leave the next column as a continuation, so the trailing 'X' lands at
# terminal column 4 (1-based) — i.e. cursor address ...;4H appears for it once
# the surrounding cells change.
{
    my $r = PerlTea::Renderer->new( cols => 10, rows => 1 );
    my $first  = $r->render("\x{4E16}\x{754C}AB");   # 世界AB
    like( $first, qr/\x{4E16}/, 'first frame contains the wide glyph' );

    # Change only the last visible character; because 世界 occupy columns 1-4,
    # 'A' is at column 5 and 'B' at column 6. Changing B must address column 6.
    my $diff = $r->render("\x{4E16}\x{754C}AC");
    like( $diff, qr/\e\[1;6H/, 'wide glyphs keep column accounting: B sits at col 6' );
    like( $diff, qr/C/,        'the changed cell is re-emitted' );
}

done_testing;
