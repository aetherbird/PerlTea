package PerlTea::Component::Help;

use strict;
use warnings;

=head1 NAME

PerlTea::Component::Help - compact key binding help bar

=head1 SYNOPSIS

    my $help = PerlTea::Component::Help->new(
        bindings => [ [ q => 'quit' ], [ tab => 'focus' ] ],
        width => 30,
    );
    print $help->view;

=cut

=head2 new

Create a help bar. Options: C<bindings> and C<width>.

=cut

sub new {
    my ( $class, %args ) = @_;
    return bless {
        bindings => $args{bindings} || [],
        width    => $args{width} || 0,
    }, $class;
}

=head2 bindings

Return the configured binding list.

=cut

sub bindings { return $_[0]->{bindings} }

=head2 view

Render the bindings as a single line, truncating to C<width> when set.

=cut

sub view {
    my ($self) = @_;
    my @parts = map { $_->[0] . ' ' . $_->[1] } @{ $self->{bindings} };
    my $line = join ' | ', @parts;
    if ( $self->{width} ) {
        $line = substr( $line, 0, $self->{width} )
            if length($line) > $self->{width};
        $line .= ' ' x ( $self->{width} - length($line) );
    }
    return $line;
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
