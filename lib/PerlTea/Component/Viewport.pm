package PerlTea::Component::Viewport;

use strict;
use warnings;

use PerlTea::Width ();

=head1 NAME

PerlTea::Component::Viewport - scrollable text viewport

=head1 SYNOPSIS

    my $vp = PerlTea::Component::Viewport->new(
        width => 40, height => 10, content => "many\nlines\n..."
    );
    $vp->scroll_down;
    print $vp->view;

=head1 DESCRIPTION

C<PerlTea::Component::Viewport> renders a fixed-size window onto multiline text.
It stores a vertical scroll offset, clamps that offset to the available content,
and always returns exactly C<height> rows of C<width> columns. It is ANSI-aware:
embedded SGR escape sequences are preserved when fitting or truncating lines so
styled content (e.g. highlighted search matches) lays out correctly.

=cut

=head2 new

Create a viewport. Options: C<width>, C<height>, C<content>, and C<offset>.

=cut

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        width   => $args{width}  || 1,
        height  => $args{height} || 1,
        lines   => [],
        offset  => $args{offset} || 0,
    };
    bless $self, $class;
    $self->set_content( $args{content} // '' );
    return $self;
}

=head2 resize

Set the viewport dimensions and clamp the current scroll offset.

=cut

sub resize {
    my ( $self, %args ) = @_;
    $self->{width}  = $args{width}  if defined $args{width};
    $self->{height} = $args{height} if defined $args{height};
    $self->{width}  = 1 if $self->{width}  < 1;
    $self->{height} = 1 if $self->{height} < 1;
    $self->_clamp;
    return $self;
}

=head2 set_content

Replace the viewport content. Accepts either a string or an arrayref of lines.

=cut

sub set_content {
    my ( $self, $content ) = @_;
    my @lines = ref $content eq 'ARRAY' ? @$content : split /\n/, "$content", -1;
    pop @lines if @lines && $lines[-1] eq '';
    @lines = ('') unless @lines;
    $self->{lines} = \@lines;
    $self->_clamp;
    return $self;
}

=head2 scroll_up

Scroll upward by C<$n> rows (default 1).

=cut

sub scroll_up {
    my ( $self, $n ) = @_;
    $self->{offset} -= defined $n ? $n : 1;
    $self->_clamp;
    return $self;
}

=head2 scroll_down

Scroll downward by C<$n> rows (default 1).

=cut

sub scroll_down {
    my ( $self, $n ) = @_;
    $self->{offset} += defined $n ? $n : 1;
    $self->_clamp;
    return $self;
}

=head2 page_up

Scroll upward by one viewport page.

=cut

sub page_up {
    my ($self) = @_;
    return $self->scroll_up( $self->{height} );
}

=head2 page_down

Scroll downward by one viewport page.

=cut

sub page_down {
    my ($self) = @_;
    return $self->scroll_down( $self->{height} );
}

=head2 goto_top

Move to the first content row.

=cut

sub goto_top {
    my ($self) = @_;
    $self->{offset} = 0;
    return $self;
}

=head2 goto_bottom

Move to the last possible viewport offset.

=cut

sub goto_bottom {
    my ($self) = @_;
    $self->{offset} = $self->_max_offset;
    return $self;
}

=head2 offset

Return the current zero-based scroll offset.

=cut

sub offset { return $_[0]->{offset} }

=head2 view

Render the visible window.

=cut

sub view {
    my ($self) = @_;
    $self->_clamp;
    my @out;
    for my $i ( 0 .. $self->{height} - 1 ) {
        my $line = $self->{lines}[ $self->{offset} + $i ];
        push @out, _fit_line( defined $line ? $line : '', $self->{width} );
    }
    return join "\n", @out;
}

sub _max_offset {
    my ($self) = @_;
    my $max = @{ $self->{lines} } - $self->{height};
    return $max > 0 ? $max : 0;
}

sub _clamp {
    my ($self) = @_;
    $self->{offset} = 0 if $self->{offset} < 0;
    my $max = $self->_max_offset;
    $self->{offset} = $max if $self->{offset} > $max;
    return;
}

sub _fit_line {
    my ( $line, $width ) = @_;
    my $vis = _visible_length($line);
    if ( $vis > $width ) {
        $line = _truncate_visible( $line, $width );
        $vis = _visible_length($line);
    }
    if ( $vis < $width ) {
        $line .= ( ' ' x ( $width - $vis ) );
    }
    return $line;
}

# Visible display width, East-Asian-aware, ANSI escapes ignored (PerlTea::Width).
sub _visible_length {
    my ($s) = @_;
    return PerlTea::Width::display_width($s);
}

# Truncate to $max visible columns while preserving embedded SGR sequences.
sub _truncate_visible {
    my ( $s, $max ) = @_;
    return PerlTea::Width::truncate_to_width( $s, $max );
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
