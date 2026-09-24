use strict;
use warnings;
use Test::More;
use PerlTea::Component::Help;

# The help bar is a stable single-line component; width fitting prevents it from
# pushing footer layouts around.
my $help = PerlTea::Component::Help->new(
    width    => 16,
    bindings => [ [ q => 'quit' ], [ tab => 'focus' ], [ '/' => 'search' ] ],
);

is( $help->view, 'q quit | tab foc', 'help view truncates to fixed width' );
is_deeply(
    $help->bindings,
    [ [ q => 'quit' ], [ tab => 'focus' ], [ '/' => 'search' ] ],
    'bindings are retained',
);

done_testing;
