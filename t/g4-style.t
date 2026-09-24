use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Encode qw(decode);
use PerlTea::Style;

# G4 — Styling. Snapshot the rendered box against a tracked golden, and verify
# 16-color downgrade removes truecolor/256-color sequences.

# Force truecolor so the golden is deterministic regardless of the test runner's
# TERM. The gate itself also relies on this env override for the snapshot.
local $ENV{COLORTERM} = 'truecolor';
delete $ENV{PERLTEA_FORCE_COLORS};

my $box = PerlTea::Style->new(
    border         => 'single',
    padding        => [ 1, 2 ],
    width          => 42,
    height         => 9,
    align          => 'center',
    vertical_align => 'middle',
    foreground     => '#e0e0e0',
    background     => '#2a0a4a',
    bold           => 1,
)->render("PerlTea G4\nStyling demo\ncount: 0");

# The golden is generated once when the gate is implemented and then tracked.
# It is stored as UTF-8 bytes because the output contains Unicode box-drawing
# characters; decode it before comparing to the internal wide-character string.
my $golden_path = "$FindBin::Bin/../testdata/g4/box.golden";
open my $gh, '<:raw', $golden_path or die "cannot open $golden_path: $!";
local $/;
my $golden = decode( 'UTF-8', <$gh> );
close $gh;

is( $box, $golden, 'styled box matches tracked golden' );

# Downgrade under PERLTEA_FORCE_COLORS=16 must strip 24-bit and 256-color codes.
{
    local $ENV{PERLTEA_FORCE_COLORS} = '16';
    local $ENV{COLORTERM} = '';
    my $box16 = PerlTea::Style->new(
        border         => 'single',
        padding        => [ 1, 2 ],
        width          => 42,
        height         => 9,
        align          => 'center',
        vertical_align => 'middle',
        foreground     => '#e0e0e0',
        background     => '#2a0a4a',
        bold           => 1,
    )->render("PerlTea G4\nStyling demo\ncount: 0");

    unlike( $box16, qr/\e\[38;2;/,  '16-color mode: no truecolor foreground' );
    unlike( $box16, qr/\e\[48;2;/,  '16-color mode: no truecolor background' );
    unlike( $box16, qr/\e\[38;5;/,  '16-color mode: no 256-color foreground' );
    unlike( $box16, qr/\e\[48;5;/,  '16-color mode: no 256-color background' );
    like( $box16, qr/\e\[[0-9;]*m/, '16-color mode: still emits some SGR styling' );
}

# Attribute passthrough: a style with bold/italic/underline emits the right codes.
my $attr = PerlTea::Style->new(
    bold      => 1,
    italic    => 1,
    underline => 1,
)->render('x');
like( $attr, qr/\e\[1;3;4m/, 'bold+italic+underline emits correct SGR' );

# Named colors and 256 colors render in the active profile.
my $named = PerlTea::Style->new( foreground => 'red', background => 'blue' )->render('x');
like( $named, qr/\e\[31;44m/, 'named 16 colors emit classic SGR codes' );

# Bright named colors in 16-color mode must map to 90..107 without crashing.
my $bright = PerlTea::Style->new(
    color_profile => '16',
    foreground    => 'bright-white',
    background    => 'bright-red',
)->render('x');
like( $bright, qr/\e\[97;101m/, 'bright named 16 colors emit high SGR codes' );

done_testing;
