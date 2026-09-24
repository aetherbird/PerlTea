package PerlTea::App::Glow;

use strict;
use warnings;
use utf8;

use PerlTea::Style;

=head1 NAME

PerlTea::App::Glow - render Markdown into ANSI-styled terminal text

=head1 SYNOPSIS

    use PerlTea::App::Glow;

    open my $fh, '<', 'README.md' or die $!;
    local $/;
    my $markdown = <$fh>;

    print PerlTea::App::Glow::render( $markdown, width => 80 );

=head1 DESCRIPTION

C<PerlTea::App::Glow> is a small Markdown renderer — the first PerlTea app and
the proof that the frozen framework holds. It turns Markdown source into styled
terminal text using the G4 styling layer (L<PerlTea::Style>): headings, bold,
italic, inline code, fenced code blocks, bullet and ordered lists, block quotes
and horizontal rules.

It is intentionally not a full CommonMark implementation — the goal is "sane
parity" (comfortably reading a README), not Glamour-level fidelity. Rendering is
a pure function of its input and the active L<PerlTea::Style> color profile, so
its output is snapshot-testable.

Block elements (headings, code blocks) are colored through L<PerlTea::Style> so
they honour the active color profile and downgrade cleanly. Inline emphasis uses
profile-independent SGR attributes (bold/italic/underline/reverse) with explicit
attribute resets so spans never clobber a surrounding style.

=cut

# Heading styles by level. Colored through PerlTea::Style (the G4 layer) so they
# downgrade with the active profile.
my %HEADING = (
    1 => { bold => 1, underline => 1, foreground => '#d787ff' },
    2 => { bold => 1, foreground => '#5fafff' },
    3 => { bold => 1, foreground => '#5fd7af' },
    4 => { bold => 1, foreground => 'cyan' },
    5 => { bold => 1, foreground => 'cyan' },
    6 => { bold => 1, foreground => 'cyan' },
);

=head2 render

    my $styled = PerlTea::App::Glow::render( $markdown, %options );

Render a Markdown string into ANSI-styled text and return it. The result is a
multi-line string (no trailing newline) suitable for handing straight to a
PerlTea C<view>.

Options:

=over 4

=item * C<width> - column width used for horizontal rules (default 80). It does
not wrap paragraph text; the renderer leaves soft-wrapping to the terminal /
viewport.

=back

Recognised block constructs: ATX headings (C<#>..C<######>), fenced code blocks
(C<```>), unordered list items (C<->/C<*>/C<+>), ordered list items (C<1.>),
block quotes (C<< > >>), horizontal rules (C<--->), and paragraphs. Recognised
inline constructs: C<**bold**>/C<__bold__>, C<*italic*>/C<_italic_>, C<`code`>,
and C<[text](url)> links (rendered as underlined text).

=cut

sub render {
    my ( $text, %opt ) = @_;
    $text = '' unless defined $text;
    my $width = $opt{width} || 80;

    my @in = split /\n/, $text, -1;
    pop @in if @in && $in[-1] eq '';    # drop the empty field from a trailing \n

    my @out;
    my $i = 0;
    while ( $i <= $#in ) {
        my $line = $in[$i];

        # Fenced code block: ``` ... ``` (an optional info string is dropped).
        if ( $line =~ /^\s*```/ ) {
            my @code;
            $i++;
            while ( $i <= $#in && $in[$i] !~ /^\s*```/ ) {
                push @code, $in[$i];
                $i++;
            }
            $i++ if $i <= $#in;    # consume the closing fence
            push @out, _render_code_block( \@code );
            next;
        }

        # ATX heading: # .. ###### text
        if ( $line =~ /^(\#{1,6})\s+(.*?)\s*\#*\s*$/ ) {
            push @out, _render_heading( length($1), $2 );
            $i++;
            next;
        }

        # Horizontal rule: ---, ***, ___ (3+).
        if ( $line =~ /^\s*([-*_])(?:\s*\1){2,}\s*$/ ) {
            push @out, _render_rule($width);
            $i++;
            next;
        }

        # Unordered list item.
        if ( $line =~ /^(\s*)[-*+]\s+(.*)$/ ) {
            push @out, _render_list_item( $1, $2 );
            $i++;
            next;
        }

        # Ordered list item.
        if ( $line =~ /^(\s*)(\d+)\.\s+(.*)$/ ) {
            push @out, _render_ordered_item( $1, $2, $3 );
            $i++;
            next;
        }

        # Block quote.
        if ( $line =~ /^\s*>\s?(.*)$/ ) {
            push @out, _render_quote($1);
            $i++;
            next;
        }

        # Blank line: preserved verbatim.
        if ( $line eq '' ) {
            push @out, '';
            $i++;
            next;
        }

        # Plain paragraph line.
        push @out, _render_inline($line);
        $i++;
    }

    return join "\n", @out;
}

# A heading is styled as a whole line through PerlTea::Style (no inline parsing,
# so a block color is never clobbered by an inline reset).
sub _render_heading {
    my ( $level, $text ) = @_;
    my $spec = $HEADING{$level} || $HEADING{6};
    return PerlTea::Style->new(%$spec)->render($text);
}

# A fenced code block: color + background applied uniformly via PerlTea::Style.
sub _render_code_block {
    my ($lines) = @_;
    my $body = join "\n", @$lines;
    return PerlTea::Style->new(
        foreground => '#d7d7af',
        background => '#262626',
        padding    => [ 0, 1 ],
    )->render($body);
}

# Unordered list item: indent + bullet + inline-styled text.
sub _render_list_item {
    my ( $indent, $text ) = @_;
    my $depth = length($indent);
    return ( ' ' x $depth ) . "  \x{2022} " . _render_inline($text);
}

# Ordered list item: indent + number + inline-styled text.
sub _render_ordered_item {
    my ( $indent, $num, $text ) = @_;
    my $depth = length($indent);
    return ( ' ' x $depth ) . "  $num. " . _render_inline($text);
}

# Block quote: a faint vertical bar gutter then italic, inline-styled text.
sub _render_quote {
    my ($text) = @_;
    return "\e[2m\x{2502}\e[22m \e[3m" . _render_inline($text) . "\e[23m";
}

# Horizontal rule: a faint full-width line of box-drawing dashes.
sub _render_rule {
    my ($width) = @_;
    $width = 1 if $width < 1;
    return "\e[2m" . ( "\x{2500}" x $width ) . "\e[22m";
}

# Inline emphasis. Profile-independent SGR with explicit attribute resets
# (22/23/24/27) so a span never wipes out a surrounding style. Code spans win
# over emphasis, so Markdown punctuation inside `code` is left literal.
sub _render_inline {
    my ($s) = @_;
    my $out = '';
    pos($s) = 0;
    while ( pos($s) < length($s) ) {
        if ( $s =~ /\G`([^`]+)`/gc ) {
            $out .= "\e[7m" . $1 . "\e[27m";    # inline code: reverse video
        }
        elsif ( $s =~ /\G\*\*(.+?)\*\*/gc ) {
            $out .= "\e[1m" . _render_inline($1) . "\e[22m";    # bold
        }
        elsif ( $s =~ /\G__(.+?)__/gc ) {
            $out .= "\e[1m" . _render_inline($1) . "\e[22m";    # bold
        }
        elsif ( $s =~ /\G\*(.+?)\*/gc ) {
            $out .= "\e[3m" . _render_inline($1) . "\e[23m";    # italic
        }
        elsif ( $s =~ /\G_(.+?)_/gc ) {
            $out .= "\e[3m" . _render_inline($1) . "\e[23m";    # italic
        }
        elsif ( $s =~ /\G\[([^\]]+)\]\(([^)]+)\)/gc ) {
            $out .= "\e[4m" . $1 . "\e[24m";    # link text: underline
        }
        elsif ( $s =~ /\G(.)/gcs ) {
            $out .= $1;
        }
        else {
            last;
        }
    }
    return $out;
}

1;

__END__

=head1 SEE ALSO

L<PerlTea>, L<PerlTea::Style>, L<PerlTea::Component::Viewport>.

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
