package PerlTea::Component::TextInput;

use strict;
use warnings;

=head1 NAME

PerlTea::Component::TextInput - editable single-line text input

=head1 SYNOPSIS

    my $input = PerlTea::Component::TextInput->new(width => 20);
    $input->insert("a");
    print $input->view;

=head1 DESCRIPTION

C<PerlTea::Component::TextInput> stores a line of text, a cursor, and focus
state. It accepts decoded PerlTea key messages through L</handle_msg>.

=cut

=head2 new

Create an input. Options: C<width>, C<value>, C<placeholder>, and C<focus>.

=cut

sub new {
    my ( $class, %args ) = @_;
    my $value = defined $args{value} ? "$args{value}" : '';
    return bless {
        width       => $args{width} || 1,
        value       => $value,
        cursor      => length($value),
        placeholder => $args{placeholder} || '',
        focus       => $args{focus} ? 1 : 0,
    }, $class;
}

=head2 set_focus

Set whether the input is focused.

=cut

sub set_focus {
    my ( $self, $focus ) = @_;
    $self->{focus} = $focus ? 1 : 0;
    return $self;
}

=head2 value

Return the current input value.

=cut

sub value { return $_[0]->{value} }

=head2 cursor

Return the current cursor position.

=cut

sub cursor { return $_[0]->{cursor} }

=head2 insert

Insert printable text at the cursor.

=cut

sub insert {
    my ( $self, $text ) = @_;
    $text = '' unless defined $text;
    substr( $self->{value}, $self->{cursor}, 0 ) = $text;
    $self->{cursor} += length($text);
    return $self;
}

=head2 backspace

Delete the character before the cursor.

=cut

sub backspace {
    my ($self) = @_;
    return $self if $self->{cursor} <= 0;
    substr( $self->{value}, $self->{cursor} - 1, 1 ) = '';
    $self->{cursor}--;
    return $self;
}

=head2 delete

Delete the character under the cursor.

=cut

sub delete {
    my ($self) = @_;
    return $self if $self->{cursor} >= length $self->{value};
    substr( $self->{value}, $self->{cursor}, 1 ) = '';
    return $self;
}

=head2 move_left

Move the cursor left.

=cut

sub move_left {
    my ($self) = @_;
    $self->{cursor}-- if $self->{cursor} > 0;
    return $self;
}

=head2 move_right

Move the cursor right.

=cut

sub move_right {
    my ($self) = @_;
    $self->{cursor}++ if $self->{cursor} < length $self->{value};
    return $self;
}

=head2 handle_msg

Apply a decoded key message from C<PerlTea::Input>.

=cut

sub handle_msg {
    my ( $self, $msg ) = @_;
    return $self unless $msg && ref $msg eq 'HASH';
    my $key = $msg->{key} // '';
    my $printable = defined $msg->{char} ? $msg->{char} : $msg->{rune};
    if ( defined $printable && length($printable) && length($printable) == 1 ) {
        return $self->insert($printable) if ord($printable) >= 32;
    }
    return $self->backspace if $key eq 'backspace' || $key eq 'ctrl+h';
    return $self->delete    if $key eq 'delete';
    return $self->move_left if $key eq 'left';
    return $self->move_right if $key eq 'right';
    return $self;
}

=head2 view

Render the input as one fixed-width line.

=cut

sub view {
    my ($self) = @_;
    my $prefix = $self->{focus} ? '[' : ' ';
    my $suffix = $self->{focus} ? ']' : ' ';
    my $body = length $self->{value} ? $self->{value} : $self->{placeholder};
    if ( $self->{focus} && length $self->{value} ) {
        substr( $body, $self->{cursor}, 0 ) = '|' if $self->{cursor} <= length $body;
    }
    return _fit_line( $prefix . $body . $suffix, $self->{width} );
}

sub _fit_line {
    my ( $line, $width ) = @_;
    $line = substr( $line, 0, $width ) if length($line) > $width;
    return $line . ( ' ' x ( $width - length($line) ) );
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
