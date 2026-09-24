use strict;
use warnings;
use Test::More;
use PerlTea::Component::TextInput;

# Text input consumes decoded PerlTea key messages and keeps cursor edits local.
my $input = PerlTea::Component::TextInput->new(
    width       => 8,
    placeholder => 'search',
    focus       => 1,
);

is( $input->view, '[search]', 'empty focused input shows placeholder' );

$input->handle_msg( { char => 'a' } );
$input->handle_msg( { char => 'b' } );
$input->handle_msg( { key  => 'left' } );
$input->handle_msg( { char => 'X' } );
is( $input->value, 'aXb', 'insert honors cursor position' );
is( $input->cursor, 2, 'cursor advances after insert' );

$input->handle_msg( { key => 'backspace' } );
is( $input->value, 'ab', 'backspace removes previous character' );

$input->set_focus(0);
is( $input->view, ' ab     ', 'unfocused view is fixed-width without cursor' );

done_testing;
