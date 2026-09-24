package PerlTea::Component::List;

use strict;
use warnings;

=head1 NAME

PerlTea::Component::List - selectable list component

=head1 SYNOPSIS

    my $list = PerlTea::Component::List->new(items => [qw(one two)]);
    $list->move_down;
    print $list->view;

=head1 DESCRIPTION

C<PerlTea::Component::List> keeps a selected item and a scroll offset, rendering
only the visible rows. A focused list marks its selected row with C<E<gt>>; an
unfocused list uses C<->.

=cut

=head2 new

Create a list. Options: C<items>, C<width>, C<height>, C<selected>, and C<focus>.

=cut

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        items    => $args{items} || [],
        width    => $args{width} || 1,
        height   => $args{height} || 1,
        selected => $args{selected} || 0,
        offset   => 0,
        focus    => $args{focus} ? 1 : 0,
    };
    bless $self, $class;
    $self->_clamp;
    return $self;
}

=head2 set_focus

Set whether the list is focused.

=cut

sub set_focus {
    my ( $self, $focus ) = @_;
    $self->{focus} = $focus ? 1 : 0;
    return $self;
}

=head2 move_up

Move the selection up by C<$n> rows (default 1).

=cut

sub move_up {
    my ( $self, $n ) = @_;
    $self->{selected} -= defined $n ? $n : 1;
    $self->_clamp;
    return $self;
}

=head2 move_down

Move the selection down by C<$n> rows (default 1).

=cut

sub move_down {
    my ( $self, $n ) = @_;
    $self->{selected} += defined $n ? $n : 1;
    $self->_clamp;
    return $self;
}

=head2 current

Return the selected item.

=cut

sub current {
    my ($self) = @_;
    return $self->{items}[ $self->{selected} ];
}

=head2 selected

Return the selected index.

=cut

sub selected { return $_[0]->{selected} }

=head2 view

Render the list.

=cut

sub view {
    my ($self) = @_;
    $self->_clamp;
    my @out;
    for my $row ( 0 .. $self->{height} - 1 ) {
        my $idx = $self->{offset} + $row;
        my $item = defined $self->{items}[$idx] ? $self->{items}[$idx] : '';
        my $mark = $idx == $self->{selected} ? ( $self->{focus} ? '>' : '-' ) : ' ';
        push @out, _fit_line( "$mark $item", $self->{width} );
    }
    return join "\n", @out;
}

sub _clamp {
    my ($self) = @_;
    my $last = @{ $self->{items} } - 1;
    $last = 0 if $last < 0;
    $self->{selected} = 0     if $self->{selected} < 0;
    $self->{selected} = $last if $self->{selected} > $last;
    if ( $self->{selected} < $self->{offset} ) {
        $self->{offset} = $self->{selected};
    }
    if ( $self->{selected} >= $self->{offset} + $self->{height} ) {
        $self->{offset} = $self->{selected} - $self->{height} + 1;
    }
    $self->{offset} = 0 if $self->{offset} < 0;
    return;
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
