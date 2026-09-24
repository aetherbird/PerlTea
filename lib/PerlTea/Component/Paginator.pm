package PerlTea::Component::Paginator;

use strict;
use warnings;

=head1 NAME

PerlTea::Component::Paginator - page counter with clamped navigation

=head1 SYNOPSIS

    my $p = PerlTea::Component::Paginator->new(total => 5);
    $p->next;
    print $p->view; # 2/5

=cut

=head2 new

Create a paginator. Options: C<page> (zero-based) and C<total>.

=cut

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        page  => $args{page}  || 0,
        total => $args{total} || 1,
    };
    bless $self, $class;
    $self->_clamp;
    return $self;
}

=head2 next

Move to the next page, clamped at the end.

=cut

sub next {
    my ($self) = @_;
    $self->{page}++;
    $self->_clamp;
    return $self;
}

=head2 prev

Move to the previous page, clamped at the start.

=cut

sub prev {
    my ($self) = @_;
    $self->{page}--;
    $self->_clamp;
    return $self;
}

=head2 set_total

Set the total number of pages and clamp the current page.

=cut

sub set_total {
    my ( $self, $total ) = @_;
    $self->{total} = $total || 1;
    $self->_clamp;
    return $self;
}

=head2 page

Return the current zero-based page.

=cut

sub page { return $_[0]->{page} }

=head2 view

Render the counter as C<current/total>.

=cut

sub view {
    my ($self) = @_;
    return ( $self->{page} + 1 ) . '/' . $self->{total};
}

sub _clamp {
    my ($self) = @_;
    $self->{total} = 1 if $self->{total} < 1;
    $self->{page} = 0 if $self->{page} < 0;
    $self->{page} = $self->{total} - 1 if $self->{page} >= $self->{total};
    return;
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
