use strict;
use warnings;
use Test::More;
use PerlTea::Component::Viewport;

# Viewports must clamp scrolling and render a stable rectangular window because
# later apps depend on rendering only the visible slice.
my $vp = PerlTea::Component::Viewport->new(
    width   => 5,
    height  => 3,
    content => "alpha\nbravo\ncharlie\ndelta",
);

is( $vp->view, "alpha\nbravo\ncharl", 'initial view is fitted to width/height' );

$vp->scroll_down(2);
is( $vp->offset, 1, 'scroll clamps to the last useful offset' );
is( $vp->view, "bravo\ncharl\ndelta", 'scrolling changes the visible window' );

$vp->page_up;
is( $vp->offset, 0, 'page_up clamps at top' );

$vp->goto_bottom;
is( $vp->offset, 1, 'goto_bottom uses max offset' );

done_testing;
