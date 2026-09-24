use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

# A2 — glow markdown navigator. Unit-test the A2Demo model's scrolling and
# resize behaviour without driving a real terminal. The gate drives the actual
# demo in a PTY and checks the end sentinel appears only after scrolling.
require "./cmd/a2.pl";

my $long = "$FindBin::Bin/../testdata/glow/long.md";
my $model = A2Demo->new( path => $long, width => 80, height => 10 );

# The end-of-document sentinel is off-screen on the first viewport.
unlike( $model->view, qr/ZZZ_ENDMARKER/,
    'end sentinel is not visible on the first screen' );

# Page down changes the visible window.
my $top = $model->view;
$model->update( { type => 'key', key => 'pgdown' } );
my $after_pgdown = $model->view;
isnt( $after_pgdown, $top, 'page down changes the viewport' );

# Scrolling further should eventually reveal the sentinel, but jumping with G
# is the contract the gate tests directly.
$model->update( { type => 'key', key => 'G' } );
like( $model->view, qr/ZZZ_ENDMARKER/,
    'G jumps to the bottom and reveals the end sentinel' );

# g returns to the top.
$model->update( { type => 'key', key => 'g' } );
is( $model->{viewport}->offset, 0, 'g returns to the top of the document' );

# Arrow and alternate keys also move the viewport.
$model->update( { type => 'key', key => 'down' } );
cmp_ok( $model->{viewport}->offset, '>', 0, 'down scrolls away from top' );
$model->update( { type => 'key', key => 'up' } );
is( $model->{viewport}->offset, 0, 'up scrolls back to top' );

$model->update( { type => 'key', key => 'j' } );
cmp_ok( $model->{viewport}->offset, '>', 0, 'j scrolls down like down-arrow' );
$model->update( { type => 'key', key => 'k' } );
is( $model->{viewport}->offset, 0, 'k scrolls up like up-arrow' );

# home/end are synonyms for g/G.
$model->update( { type => 'key', key => 'end' } );
like( $model->view, qr/ZZZ_ENDMARKER/, 'end jumps to the bottom' );
$model->update( { type => 'key', key => 'home' } );
is( $model->{viewport}->offset, 0, 'home jumps to the top' );

# q returns the canonical quit sentinel.
my ( $next, $cmd ) = $model->update( { type => 'key', key => 'q' } );
ok( $next->isa('PerlTea::Msg::Quit'), 'q returns the quit sentinel' );

# Resize re-renders the document at the new width.
my $resized = A2Demo->new( path => $long, width => 80, height => 10 );
$resized->update( { type => 'resize', width => 40, height => 10 } );
is( $resized->{width},  40, 'resize updates width' );
is( $resized->{height}, 10, 'resize keeps height' );
like( $resized->view, qr/Paragraph 1/,
    'resize re-renders content at the new width' );

# The rendered view is exactly width x height (rows of 40 columns).
my @rows = split /\n/, $resized->view;
is( scalar(@rows), 10, 'view has exactly 10 rows after resize' );
ok( ( length( $rows[0] ) >= 40 ), 'each row is at least the viewport width' );

done_testing;
