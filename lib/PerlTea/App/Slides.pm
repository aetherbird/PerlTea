package PerlTea::App::Slides;

use strict;
use warnings;
use utf8;

use PerlTea;
use PerlTea::App::Glow;
use PerlTea::Component::Paginator;
use PerlTea::Layout;
use PerlTea::Style;
use PerlTea::Width ();

=head1 NAME

PerlTea::App::Slides - render a Markdown deck as terminal slides

=head1 SYNOPSIS

    use PerlTea;
    use PerlTea::App::Slides;

    my $deck = PerlTea::App::Slides->new( path => 'deck.md' );
    PerlTea->new( model => $deck, alt_screen => 1 )->run;

=head1 DESCRIPTION

C<PerlTea::App::Slides> is the shared model behind the C-series slide demos. It
splits a Markdown file on C<---> delimiter lines, renders each slide through
L<PerlTea::App::Glow>, and displays one slide at a time with a counter. It is a
PerlTea model: C<update>, C<view>, and C<init> hooks wired into the framework.

The deck splitter is exposed as a pure function so unit tests can verify slide
count and content without driving a terminal.

=cut

=head2 split_deck

    my $slides = PerlTea::App::Slides::split_deck($markdown);

Split Markdown source into slide chunks on C<^---$> delimiter lines. Returns an
arrayref of strings (possibly empty if the input has no slides). Surrounding
blank lines are trimmed from each chunk.

=cut

sub split_deck {
    my ($text) = @_;
    $text = '' unless defined $text;
    my @parts = split /^---\s*$/m, $text, -1;

    my @slides;
    for my $part (@parts) {
        $part =~ s/^\s+\n|\s+$/ /s;
        $part =~ s/^\s+|\s+$//g;
        push @slides, $part;
    }
    return \@slides;
}

=head2 render_slide

    my $styled = PerlTea::App::Slides::render_slide($markdown, width => 80);

Render a single slide's Markdown into ANSI-styled text using
L<PerlTea::App::Glow>. The result is a multi-line string with no trailing
newline.

=cut

sub render_slide {
    my ( $text, %opt ) = @_;
    my $width = $opt{width} || 80;
    return PerlTea::App::Glow::render( $text, width => $width );
}

=head2 new

    my $app = PerlTea::App::Slides->new(
        path   => 'deck.md',
        width  => 80,
        height => 24,
    );

Construct the slide model. Loads the deck from C<path>, splits and renders the
slides, and prepares the paginator. Options: C<path> (required), C<width>,
C<height>, and C<page> (zero-based starting slide, default 0).

=cut

sub new {
    my ( $class, %args ) = @_;

    my $path = $args{path}
        or die "PerlTea::App::Slides->new requires a 'path' argument\n";

    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot open $path: $!\n";
    local $/;
    my $markdown = <$fh>;
    close $fh;

    my $width  = $args{width}  || 80;
    my $height = $args{height} || 24;

    my $raw_slides = split_deck($markdown);
    @$raw_slides = ('') unless @$raw_slides;

    my @rendered = map { render_slide( $_, width => $width ) } @$raw_slides;

    my $self = bless {
        path       => $path,
        width      => $width,
        height     => $height,
        raw        => $raw_slides,
        slides     => \@rendered,
        paginator  => PerlTea::Component::Paginator->new(
            page  => $args{page} || 0,
            total => scalar(@rendered),
        ),
    }, $class;

    return $self;
}

=head2 init

PerlTea model hook. No startup command.

=cut

sub init { return undef }

=head2 total

Return the total number of slides in the deck.

=cut

sub total { return scalar( @{ $_[0]->{slides} } ) }

=head2 current

Return the current zero-based slide index.

=cut

sub current { return $_[0]->{paginator}{page} }

=head2 next_slide

Advance to the next slide, clamped at the end. Returns the model.

=cut

sub next_slide {
    my ($self) = @_;
    $self->{paginator}->next;
    return $self;
}

=head2 prev_slide

Go back to the previous slide, clamped at the start. Returns the model.

=cut

sub prev_slide {
    my ($self) = @_;
    $self->{paginator}->prev;
    return $self;
}

=head2 update

PerlTea model hook. Handles C<resize> (re-render the deck at the new width),
forward navigation (C<right> arrow, C<l>, C<n>, space), backward navigation
(C<left> arrow, C<h>, C<p>), and C<q> to quit. Navigation clamps at both ends
via the paginator, so the counter never underflows below C<1/N> or past
C<N/N>.

=cut

# Keys that advance / rewind the deck. Arrows arrive as 'left'/'right'; the
# vi-style and presenter aliases (h/l, p/n) and space arrive as runes.
my %NEXT_KEY = map { $_ => 1 } qw( right l n space );
my %PREV_KEY = map { $_ => 1 } qw( left h p );

sub update {
    my ( $self, $msg ) = @_;

    if ( ( $msg->{type} // '' ) eq 'resize' ) {
        $self->{width}  = $msg->{width}  if $msg->{width};
        $self->{height} = $msg->{height} if $msg->{height};
        $self->{slides} = [
            map { render_slide( $_, width => $self->{width} ) }
                @{ $self->{raw} }
        ];
        return ( $self, undef );
    }

    my $key = $msg->{key} // '';
    return ( PerlTea->quit, undef ) if $key eq 'q';

    $self->next_slide if $NEXT_KEY{$key};
    $self->prev_slide if $PREV_KEY{$key};

    return ( $self, undef );
}

=head2 view

PerlTea model hook. Render the current slide framed between a prominent title
header and a key-hint / position footer. The slide body is centered
(horizontally and vertically) in the area between the two rules. The output is
exactly C<width> columns by C<height> rows.

Layout (top to bottom):

    row 0           a plain horizontal rule (top of the frame)
    row 1           reversed header: deck name + the current slide's title
    rows 2..h-3     the centered, Glow-rendered slide body
    row h-2         a faint horizontal rule
    row h-1         footer: key hints (left) + "n/Total" position (right)

The top rule on row 0 is deliberately left unstyled so the rendered view's
first physical row is exactly C<width> characters wide (no SGR escapes inflate
its length).

=cut

sub view {
    my ($self) = @_;

    my $w = $self->{width};
    my $h = $self->{height};

    my $page  = $self->{paginator}{page};
    my $slide = $self->{slides}[$page] // '';
    my $total = $self->total;

    # Frame: top rule + header + bottom rule + footer == 4 rows. The body is
    # whatever remains; clamp to at least one row on tiny terminals.
    my $frame_rows = $h >= 5 ? 4 : 0;
    my $body_height = $h - $frame_rows;
    $body_height = 1 if $body_height < 1;
    my $body = _center( $slide, $w, $body_height );

    if ( !$frame_rows ) {    # degenerate terminal: body only, sized exactly
        return PerlTea::Layout->vertical(
            width    => $w,
            height   => $h,
            children => [ { content => $body, size => $body_height } ],
        )->render;
    }

    my $top_rule = "\x{2500}" x $w;          # plain (escape-free) top rule
    my $bot_rule = _rule($w);                # faint bottom rule
    my $header   = $self->_header( $page, $total );

    # Footer: key hints flush-left, the "n/Total" position flush-right. The
    # position token still slides toward the right edge as the deck advances,
    # so the diffing renderer re-emits the whole "n/N" token on navigation.
    my $count  = $self->{paginator}->view;
    my $footer = $self->_footer( $count, $page, $total );

    my $ui = PerlTea::Layout->vertical(
        width    => $w,
        height   => $h,
        children => [
            { content => $top_rule, size => 1 },
            { content => $header,   size => 1 },
            { content => $body,     size => $body_height },
            { content => $bot_rule, size => 1 },
            { content => $footer,   size => 1 },
        ],
    );

    return $ui->render;
}

# Prominent header: the deck's filename and the current slide's title, drawn in
# reverse video across the full width so it reads as a title bar.
sub _header {
    my ( $self, $page, $total ) = @_;

    my $deck = $self->{path};
    $deck =~ s{.*/}{};            # basename only
    my $title = _slide_title( $self->{raw}[$page] );

    my $left  = $title ? "$deck \x{2014} $title" : $deck;
    my $right = 'PerlTea Slides';
    my $text  = _ends( " $left ", "$right ", $self->{width} );

    return PerlTea::Style->new(
        width   => $self->{width},
        height  => 1,
        reverse => 1,
        bold    => 1,
        align   => 'left',
    )->render($text);
}

# Footer: key hints flush-left, the slide position riding a progress track on
# the right. The position token's column is proportional to the current slide,
# so it slides rightward as you advance — a position indicator in its own right,
# and the reason the diffing renderer re-emits the whole "n/N" token (not just a
# single digit) on navigation. The whole line is dimmed so it sits quietly.
sub _footer {
    my ( $self, $count, $page, $total ) = @_;

    my $hints = 'left/right: prev/next   space: next   q: quit';
    my $text  = $self->_footer_text( $hints, $count, $page, $total );

    return PerlTea::Style->new(
        width  => $self->{width},
        height => 1,
        faint  => 1,
        align  => 'left',
    )->render($text);
}

# Build the unstyled footer line: a left hint region plus the "n/Total" counter
# placed on a progress track spanning the right region.
sub _footer_text {
    my ( $self, $hints, $count, $page, $total ) = @_;
    my $width = $self->{width};

    my $left = " $hints";
    my $lw   = _vis_len($left);
    my $clen = length $count;

    # Track region: from just after the hints to the right edge (one trailing
    # space of breathing room). Fall back to a flush-right counter if it would
    # collide with the hints.
    my $track_start = $lw + 3;            # a little gap after the hints
    my $track_end   = $width - 1;         # leave one cell at the very edge
    my $span        = $track_end - $clen - $track_start;

    my $row = ' ' x $width;
    substr( $row, 0, $lw ) = $left if $lw <= $width;

    if ( $span < 0 || $total <= 1 ) {
        # No room for a track (or a single slide): pin the counter flush-right.
        my $start = $width - $clen - 1;
        $start = $lw + 1 if $start < $lw + 1;
        substr( $row, $start, $clen ) = $count
            if $start >= 0 && $start + $clen <= $width;
        return $row;
    }

    my $start = $track_start + int( $page * $span / ( $total - 1 ) + 0.5 );
    $start = $track_start            if $start < $track_start;
    $start = $width - $clen          if $start + $clen > $width;
    substr( $row, $start, $clen ) = $count;
    return $row;
}

# Pull a slide's title: the text of its first ATX heading (e.g. "# Slide One"),
# or the first non-blank line, trimmed. Returns '' when nothing usable is found.
sub _slide_title {
    my ($raw) = @_;
    return '' unless defined $raw && length $raw;
    for my $line ( split /\n/, $raw ) {
        next if $line =~ /^\s*$/;
        ( my $t = $line ) =~ s/^\s*#+\s*//;    # strip ATX marker if present
        $t =~ s/\s+$//;
        return $t;
    }
    return '';
}

# A faint full-width horizontal rule of box-drawing dashes, framing the body.
sub _rule {
    my ($width) = @_;
    return PerlTea::Style->new( faint => 1 )->render( "\x{2500}" x $width );
}

# Lay $left flush-left and $right flush-right on one unstyled line of $width
# columns, padding the gap with spaces. If they would collide, $left wins and
# $right is dropped. ANSI/East-Asian aware via the visible-width helper.
sub _ends {
    my ( $left, $right, $width ) = @_;
    my $lw = _vis_len($left);
    my $rw = _vis_len($right);
    if ( $lw + $rw + 1 > $width ) {
        return _truncate( $left, $width );
    }
    my $gap = $width - $lw - $rw;
    return $left . ( ' ' x $gap ) . $right;
}

# Center a (possibly multi-line, possibly ANSI-styled) block in a width x height
# area: pad blank rows above/below evenly, and left-pad each line so the block is
# horizontally centered on its widest line. ANSI-aware so styled slides center on
# their visible width, not their byte length.
sub _center {
    my ( $text, $width, $height ) = @_;
    my @lines = split /\n/, $text, -1;
    pop @lines while @lines > 1 && $lines[-1] eq '';

    my $maxw = 0;
    for my $l (@lines) {
        my $w = _vis_len($l);
        $maxw = $w if $w > $maxw;
    }
    my $pad = int( ( $width - $maxw ) / 2 );
    $pad = 0 if $pad < 0;
    @lines = map { ( ' ' x $pad ) . $_ } @lines;

    my $top = int( ( $height - scalar(@lines) ) / 2 );
    $top = 0 if $top < 0;
    my @rows = ('') x $top;
    push @rows, @lines;
    return join "\n", @rows;
}

# Visible display width: East-Asian-aware, ANSI escapes ignored (PerlTea::Width).
sub _vis_len {
    my ($s) = @_;
    return PerlTea::Width::display_width($s);
}

# Truncate to a visible column budget (East-Asian-aware, ANSI-safe).
sub _truncate {
    my ( $s, $max ) = @_;
    return PerlTea::Width::truncate_to_width( $s, $max );
}

1;

__END__

=head1 SEE ALSO

L<PerlTea>, L<PerlTea::App::Glow>, L<PerlTea::Component::Paginator>,
L<PerlTea::Layout>.

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
