use strict;
use warnings;
use Test::More;
use PerlTea::Component::Spinner;

# Spinner advancement is explicit and deterministic so subscriptions can drive it
# without hidden timing dependencies in tests.
my $spin = PerlTea::Component::Spinner->new(
    frames => [qw(a b c)],
    label  => 'work',
);

is( $spin->view, 'a work', 'initial frame renders with label' );
$spin->tick;
is( $spin->frame, 'b', 'tick advances one frame' );
$spin->tick->tick;
is( $spin->frame, 'a', 'frames wrap around' );

done_testing;
