package PerlTea::Layout;

use strict;
use warnings;
use Scalar::Util qw(blessed);
use PerlTea::Width ();

=head1 NAME

PerlTea::Layout - vertical/horizontal stacks with fixed and flexible sizing

=head1 SYNOPSIS

    use PerlTea::Layout;

    my $ui = PerlTea::Layout->vertical(
        width    => 80,
        height   => 24,
        children => [
            { content => $header, size => 3 },   # fixed 3 rows
            { content => $body,   flex => 1 },    # fills remaining space
            { content => $footer, size => 1 },    # fixed 1 row
        ],
    );

    print $ui->render;

=head1 DESCRIPTION

C<PerlTea::Layout> composes blocks of text into a sized grid without the caller
ever naming an absolute screen coordinate. A layout is a stack — C<vertical> or
C<horizontal> — of children. Each child is fitted into the cell it is allocated
along the stack's I<main> axis (rows for a vertical stack, columns for a
horizontal one) and stretched to fill the I<cross> axis.

Children carry a sizing hint:

=over 4

=item * C<size> — a fixed number of cells on the main axis.

=item * C<flex> — a weight; flexible children share the space left over after the
fixed children, in proportion to their weights.

=item * neither — a plain-string child takes its B<natural> size (its line count
for a vertical stack, its widest line for a horizontal one); a nested
C<PerlTea::Layout> child defaults to C<< flex => 1 >> so it fills.

=back

A child's C<content> may itself be a C<PerlTea::Layout>, which is rendered at the
size it is allocated — this is how layouts nest. Output is always exactly the
requested width and height: short content is padded with spaces, overflowing
content is truncated. ANSI SGR escape sequences in the content are not counted
toward a line's visible width, so styled blocks (see L<PerlTea::Style>) lay out
correctly.

=cut

=head2 vertical

    my $layout = PerlTea::Layout->vertical( %opts );

Construct a vertical stack (children placed top to bottom). Options: C<width>,
C<height>, and C<children> (an arrayref of child descriptors, see L</add>).

=cut

sub vertical { my $class = shift; return $class->_new( 'vertical', @_ ) }

=head2 horizontal

    my $layout = PerlTea::Layout->horizontal( %opts );

Construct a horizontal stack (children placed left to right). Same options as
L</vertical>.

=cut

sub horizontal { my $class = shift; return $class->_new( 'horizontal', @_ ) }

sub _new {
    my ( $class, $direction, %args ) = @_;
    my $self = {
        direction => $direction,
        width     => $args{width},
        height    => $args{height},
        children  => [],
    };
    bless $self, $class;
    if ( $args{children} && ref $args{children} eq 'ARRAY' ) {
        $self->add($_) for @{ $args{children} };
    }
    return $self;
}

=head2 add

    $layout->add( { content => $thing, size => 3 } );
    $layout->add( $string );                 # natural size
    $layout->add( $nested_layout );          # defaults to flex => 1

Append a child. A child is a hashref with a C<content> key (a string or a nested
C<PerlTea::Layout>) and an optional C<size> or C<flex> hint; a bare string or
layout is wrapped automatically. Returns the layout so calls can chain.

=cut

sub add {
    my ( $self, $child ) = @_;
    if ( ref $child eq 'HASH' && exists $child->{content} ) {
        push @{ $self->{children} }, { %$child };
    }
    else {
        push @{ $self->{children} }, { content => $child };
    }
    return $self;
}

=head2 render

    my $string = $layout->render;
    my $string = $layout->render( width => 100, height => 40 );

Lay the children out and return the composed string: exactly C<height> lines,
each exactly C<width> visible columns. C<width>/C<height> default to the values
the layout was constructed with; if still undefined they are derived from the
children's natural sizes.

=cut

sub render {
    my ( $self, %opt ) = @_;
    my $w = defined $opt{width}  ? $opt{width}  : $self->{width};
    my $h = defined $opt{height} ? $opt{height} : $self->{height};
    ( $w, $h ) = $self->_natural_dims( $w, $h );
    return $self->_render_sized( $w, $h );
}

# Resolve any undefined dimension from the children's natural sizes so render()
# can always work with concrete numbers.
sub _natural_dims {
    my ( $self, $w, $h ) = @_;
    return ( $w, $h ) if defined $w && defined $h;

    my $vert = $self->{direction} eq 'vertical';
    my ( $main, $cross ) = ( 0, 0 );
    for my $k ( @{ $self->{children} } ) {
        my ( $rows, $cols ) = _measure( $k->{content} );
        if ($vert) { $main += $rows; $cross = $cols if $cols > $cross; }
        else       { $main += $cols; $cross = $rows if $rows > $cross; }
    }

    if ($vert) { $w = $cross unless defined $w; $h = $main  unless defined $h; }
    else       { $w = $main  unless defined $w; $h = $cross unless defined $h; }
    $w = 1 if !$w;
    $h = 1 if !$h;
    return ( $w, $h );
}

# The core: render this stack at a concrete width x height.
sub _render_sized {
    my ( $self, $width, $height ) = @_;
    my $vert       = $self->{direction} eq 'vertical';
    my $main_total = $vert ? $height : $width;
    my $cross      = $vert ? $width  : $height;
    my @kids       = @{ $self->{children} };

    # Allocate the main axis: fixed/natural children take their size, flexible
    # children split what remains in proportion to their weights.
    my @alloc;
    my $fixed = 0;
    my @flex_idx;
    my $flex_sum = 0;

    for my $i ( 0 .. $#kids ) {
        my $k = $kids[$i];
        if ( defined $k->{size} ) {
            $alloc[$i] = $k->{size};
            $fixed += $k->{size};
        }
        elsif ( defined $k->{flex} ) {
            $alloc[$i] = undef;
            push @flex_idx, $i;
            $flex_sum += $k->{flex};
        }
        elsif ( blessed( $k->{content} ) && $k->{content}->isa('PerlTea::Layout') ) {
            $k->{flex} = 1;       # a nested layout fills by default
            $alloc[$i] = undef;
            push @flex_idx, $i;
            $flex_sum += 1;
        }
        else {
            my ( $rows, $cols ) = _measure( $k->{content} );
            my $nat = $vert ? $rows : $cols;
            $alloc[$i] = $nat;
            $fixed += $nat;
        }
    }

    my $remaining = $main_total - $fixed;
    $remaining = 0 if $remaining < 0;

    if (@flex_idx) {
        my $acc = 0;
        for my $i (@flex_idx) {
            my $share = $flex_sum > 0
                ? int( $remaining * $kids[$i]{flex} / $flex_sum )
                : 0;
            $alloc[$i] = $share;
            $acc += $share;
        }
        $alloc[ $flex_idx[-1] ] += ( $remaining - $acc );    # rounding leftover
    }

    # Render each child into its allocated block.
    my @blocks;
    for my $i ( 0 .. $#kids ) {
        my $main = $alloc[$i];
        $main = 0 if !defined $main || $main < 0;
        my ( $rows, $cols ) = $vert ? ( $main, $cross ) : ( $cross, $main );
        push @blocks, _render_child( $kids[$i], $rows, $cols );
    }

    return $vert
        ? _assemble_vertical( \@blocks, $width, $height )
        : _assemble_horizontal( \@blocks, $width, $height );
}

# Render one child (string or nested layout) and fit it to rows x cols.
sub _render_child {
    my ( $child, $rows, $cols ) = @_;
    my $content = $child->{content};
    my $str;
    if ( blessed($content) && $content->isa('PerlTea::Layout') ) {
        $str = $content->_render_sized( $cols, $rows );
    }
    else {
        $str = defined $content ? "$content" : '';
    }
    return _fit( $str, $rows, $cols );
}

sub _assemble_vertical {
    my ( $blocks, $width, $height ) = @_;
    my @lines;
    push @lines, split( /\n/, $_, -1 ) for @$blocks;
    push @lines, ' ' x $width while @lines < $height;
    @lines = @lines[ 0 .. $height - 1 ] if @lines > $height;
    $_ = _fit_line( $_, $width ) for @lines;
    return join "\n", @lines;
}

sub _assemble_horizontal {
    my ( $blocks, $width, $height ) = @_;
    my @cols = map { [ split /\n/, $_, -1 ] } @$blocks;
    my @out;
    for my $row ( 0 .. $height - 1 ) {
        my $line = '';
        for my $c (@cols) {
            $line .= defined $c->[$row] ? $c->[$row] : '';
        }
        push @out, $line;
    }
    $_ = _fit_line( $_, $width ) for @out;
    return join "\n", @out;
}

# ── fitting / measuring helpers (ANSI-aware) ─────────────────────────────────

# Make $str exactly $rows lines, each exactly $cols visible columns.
sub _fit {
    my ( $str, $rows, $cols ) = @_;
    my @lines = split /\n/, $str, -1;
    push @lines, '' while @lines < $rows;
    @lines = @lines[ 0 .. $rows - 1 ] if @lines > $rows;
    $_ = _fit_line( $_, $cols ) for @lines;
    return join "\n", @lines;
}

sub _fit_line {
    my ( $line, $cols ) = @_;
    my $len = _vis_len($line);
    return $line . ( ' ' x ( $cols - $len ) ) if $len < $cols;
    return _truncate_vis( $line, $cols ) if $len > $cols;
    return $line;
}

# Natural size of a piece of content: (rows, cols). A nested layout has no
# intrinsic size (it stretches), so it measures as (0, 0).
sub _measure {
    my ($content) = @_;
    return ( 0, 0 ) unless defined $content;
    return ( 0, 0 ) if blessed($content) && $content->isa('PerlTea::Layout');
    my @lines = split /\n/, "$content", -1;
    pop @lines if @lines && $lines[-1] eq '';
    my $w = 0;
    for (@lines) {
        my $l = _vis_len($_);
        $w = $l if $l > $w;
    }
    return ( scalar(@lines), $w );
}

# Visible display width: East-Asian-aware, ANSI escapes ignored (PerlTea::Width).
sub _vis_len {
    my ($s) = @_;
    return PerlTea::Width::display_width($s);
}

# Truncate to $max visible columns while preserving any embedded escapes.
sub _truncate_vis {
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
