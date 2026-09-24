package PerlTea::Component::Spinner;

use strict;
use warnings;

=head1 NAME

PerlTea::Component::Spinner - deterministic frame spinner

=head1 SYNOPSIS

    my $spinner = PerlTea::Component::Spinner->new(label => 'loading');
    $spinner->tick;
    print $spinner->view;

=head1 DESCRIPTION

C<PerlTea::Component::Spinner> cycles through a set of text frames. It is driven
explicitly by L</tick>, making it deterministic in tests and subscriptions.

=cut

=head2 new

Create a spinner. Options: C<frames>, C<label>, and C<index>.

=cut

sub new {
    my ( $class, %args ) = @_;
    my $frames = $args{frames} || [ '-', '\\', '|', '/' ];
    return bless {
        frames => [@$frames],
        label  => $args{label} || '',
        index  => $args{index} || 0,
    }, $class;
}

=head2 tick

Advance to the next frame.

=cut

sub tick {
    my ($self) = @_;
    my $n = @{ $self->{frames} } || 1;
    $self->{index} = ( $self->{index} + 1 ) % $n;
    return $self;
}

=head2 frame

Return the current frame string.

=cut

sub frame {
    my ($self) = @_;
    return $self->{frames}[ $self->{index} % @{ $self->{frames} } ];
}

=head2 view

Render the current spinner frame and optional label.

=cut

sub view {
    my ($self) = @_;
    my $frame = $self->frame;
    return length $self->{label} ? "$frame $self->{label}" : $frame;
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
