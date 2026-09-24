use strict;
use warnings;
use Test::More;
use PerlTea::Component::List;

# List selection must stay visible and clamped so focus/navigation demos cannot
# wander outside the item set.
my $list = PerlTea::Component::List->new(
    width  => 8,
    height => 2,
    items  => [qw(alpha bravo charlie)],
    focus  => 1,
);

like( $list->view, qr/^> alpha/, 'focused selected row uses active marker' );

$list->move_down(2);
is( $list->selected, 2, 'selection moves down' );
is( $list->current, 'charlie', 'current returns selected item' );
like( $list->view, qr/> charl/, 'selected item stays visible after scroll' );

$list->move_down(9);
is( $list->selected, 2, 'selection clamps at end' );

$list->set_focus(0);
like( $list->view, qr/- charl/, 'unfocused selected row uses inactive marker' );

done_testing;
