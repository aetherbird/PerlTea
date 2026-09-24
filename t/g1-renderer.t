use strict;
use warnings;
use Test::More;
use PerlTea::Renderer;

my $golden = 'testdata/g1/diff.golden';

# The renderer's core contract is the one-cell update: after the first full frame,
# changing one cell should emit one cursor move and one printable byte, not a full
# clear/repaint. The acceptance gate mutates this file to prove we read it.
open my $gf, '<:raw', $golden or die "open $golden: $!";
my $expected = do { local $/; <$gf> };
chomp $expected;

my $r = PerlTea::Renderer->new( cols => 10, rows => 3 );
$r->render("counter: 1\nstable\n");
my $diff = $r->render("counter: 2\nstable\n");

is( $diff, $expected, 'one-cell change matches the golden byte stream' );
ok( length($diff) <= 10, 'one-cell change emits only a few bytes' );
unlike( $diff, qr/\e\[2J/, 'one-cell change does not clear the screen' );

done_testing;
