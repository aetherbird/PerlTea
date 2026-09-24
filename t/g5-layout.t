use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Encode qw(decode);

# G5 — Layout. The header/body/footer demo must reflow correctly at three
# terminal sizes. We compare the demo's pure view function (G5Demo::view_for) to
# a tracked golden per size. Each golden is mutation-checked by the gate, so an
# empty/keyword test cannot pass.
#
# Force truecolor so the styled header/footer are deterministic regardless of the
# runner's TERM — the goldens were generated under the same setting.
local $ENV{COLORTERM} = 'truecolor';
delete $ENV{PERLTEA_FORCE_COLORS};

# Load the demo without running its event loop (it guards run() with `unless
# caller`), exposing G5Demo::view_for.
require "$FindBin::Bin/../cmd/g5.pl";

# Read a UTF-8 golden into a wide-character string for comparison with view_for.
sub read_golden {
    my ($name) = @_;
    my $path = "$FindBin::Bin/../testdata/g5/$name";
    open my $fh, '<:raw', $path or die "cannot open $path: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return decode( 'UTF-8', $bytes );
}

my %size = (
    '80x24.golden'  => [ 80,  24 ],
    '40x12.golden'  => [ 40,  12 ],
    '120x40.golden' => [ 120, 40 ],
);

# 1. Each size matches its golden.
for my $g ( sort keys %size ) {
    my ( $w, $h ) = @{ $size{$g} };
    my $view = G5Demo::view_for( $w, $h, 0 );
    is( $view, read_golden($g), "layout matches golden at ${w}x${h}" );
}

# 2. Structural guarantees: the rendered view is exactly width x height, so the
#    renderer never has to clip or pad it. (Catches off-by-one sizing bugs that a
#    golden alone might not localize.)
for my $g ( sort keys %size ) {
    my ( $w, $h ) = @{ $size{$g} };
    my $view  = G5Demo::view_for( $w, $h, 0 );
    my @lines = split /\n/, $view, -1;
    is( scalar(@lines), $h, "view at ${w}x${h} has exactly $h rows" );
    my $bad = 0;
    for my $ln (@lines) {
        ( my $vis = $ln ) =~ s/\e\[[0-9;?]*[a-zA-Z]//g;    # strip ANSI
        $bad++ if length($vis) != $w;
    }
    is( $bad, 0, "every row at ${w}x${h} is exactly $w visible columns" );
}

# 3. Reflow: different sizes must produce different output (the heart of G5).
my $v80  = G5Demo::view_for( 80,  24, 0 );
my $v40  = G5Demo::view_for( 40,  12, 0 );
my $v120 = G5Demo::view_for( 120, 40, 0 );
isnt( $v80, $v40,  '80x24 and 40x12 differ (reflow)' );
isnt( $v80, $v120, '80x24 and 120x40 differ (reflow)' );

# 4. Layout unit checks independent of the demo: fixed + flexible + nesting.
use PerlTea::Layout;
{
    my $out = PerlTea::Layout->vertical(
        width    => 10,
        height   => 5,
        children => [
            { content => 'TOP',    size => 1 },
            { content => 'MIDDLE', flex => 1 },
            { content => 'BOT',    size => 1 },
        ],
    )->render;
    my @rows = split /\n/, $out, -1;
    is( scalar(@rows), 5, 'vertical stack fills the requested height' );
    like( $rows[0], qr/^TOP\s+$/, 'fixed top row at the top' );
    like( $rows[4], qr/^BOT\s+$/, 'fixed bottom row at the bottom' );
    is( length($rows[2]), 10, 'flex row stretched to full width' );
}
{
    # Horizontal split: two flex columns share the width evenly.
    my $out = PerlTea::Layout->horizontal(
        width    => 8,
        height   => 1,
        children => [
            { content => 'L', flex => 1 },
            { content => 'R', flex => 1 },
        ],
    )->render;
    is( length($out), 8, 'horizontal stack fills the requested width' );
    is( substr( $out, 0, 1 ), 'L', 'left column starts at column 0' );
    is( substr( $out, 4, 1 ), 'R', 'right column starts at the halfway point' );
}
{
    # Nesting: a horizontal stack inside a vertical one renders at its allocation.
    my $inner = PerlTea::Layout->horizontal(
        children => [
            { content => 'a', flex => 1 },
            { content => 'b', flex => 1 },
        ],
    );
    my $out = PerlTea::Layout->vertical(
        width    => 6,
        height   => 2,
        children => [
            { content => 'HEAD',  size => 1 },
            { content => $inner,  flex => 1 },
        ],
    )->render;
    my @rows = split /\n/, $out, -1;
    is( scalar(@rows), 2, 'nested layout keeps the outer height' );
    is( length( $rows[1] ), 6, 'nested layout fills the outer width' );
    is( substr( $rows[1], 0, 1 ), 'a', 'nested left cell present' );
    is( substr( $rows[1], 3, 1 ), 'b', 'nested right cell present' );
}

done_testing;
