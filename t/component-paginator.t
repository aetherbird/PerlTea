use strict;
use warnings;
use Test::More;
use PerlTea::Component::Paginator;

# Paginators must clamp because apps use their displayed counter as user-visible
# navigation state.
my $p = PerlTea::Component::Paginator->new( total => 3 );

is( $p->view, '1/3', 'initial counter is one-based' );
$p->prev;
is( $p->page, 0, 'prev clamps at first page' );

$p->next->next->next;
is( $p->page, 2, 'next clamps at last page' );
is( $p->view, '3/3', 'last page counter renders correctly' );

$p->set_total(2);
is( $p->view, '2/2', 'set_total clamps current page' );

done_testing;
