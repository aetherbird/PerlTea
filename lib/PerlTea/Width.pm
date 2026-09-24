package PerlTea::Width;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(char_width display_width truncate_to_width);

=head1 NAME

PerlTea::Width - East-Asian-aware display width for terminal rendering

=head1 SYNOPSIS

    use PerlTea::Width qw(char_width display_width);

    char_width("a")        == 1;   # normal rune
    char_width("\x{4e16}") == 2;   # 世 — East Asian Wide glyph
    char_width("\x{0301}") == 0;   # combining acute accent

    display_width("a\x{4e16}")        == 3;   # 1 + 2
    display_width("\e[1mx\e[0m")      == 1;   # SGR escapes are not cells

=head1 DESCRIPTION

A terminal cell is one column wide, but a single Unicode character does not
always occupy one column. East Asian Wide and Fullwidth glyphs (CJK ideographs,
fullwidth forms) take B<two> columns; combining marks and zero-width characters
take B<zero>. Counting characters with C<length> therefore mis-aligns any text
containing such runes.

This module is the one place PerlTea decides how many columns a character or a
string occupies. The renderer and every component that pads, truncates, or
centers text routes its width math through here, so wide and zero-width text
lines up the same way everywhere.

Widths follow the common C<wcwidth> conventions, derived from Perl's built-in
Unicode tables (C<\p{East_Asian_Width}>, C<\p{Mn}>, C<\p{Me}>) rather than a
hand-maintained codepoint table.

=cut

=head2 char_width

    my $cols = char_width($char);

Return the number of terminal columns a single character occupies: C<0> for
combining marks, zero-width characters, and control characters; C<2> for East
Asian Wide and Fullwidth glyphs; C<1> for everything else. An empty or undefined
argument is C<0>.

=cut

# Memoize per-character widths: the Unicode-property regexes below are correct
# but comparatively slow, and rendering re-measures the same glyphs constantly.
my %WIDTH_CACHE;

sub char_width {
    my ($ch) = @_;
    return 0 unless defined $ch && length $ch;
    return $WIDTH_CACHE{$ch} if exists $WIDTH_CACHE{$ch};
    return $WIDTH_CACHE{$ch} = _compute_char_width($ch);
}

sub _compute_char_width {
    my ($ch) = @_;
    my $cp = ord $ch;

    # NUL and C0/C1 control characters do not advance the cursor.
    return 0 if $cp == 0;
    return 0 if $cp < 0x20;
    return 0 if $cp >= 0x7F && $cp < 0xA0;

    # Explicit zero-width characters (ZWSP, ZWNJ, ZWJ, word joiner, BOM).
    return 0 if $cp == 0x200B || $cp == 0x200C || $cp == 0x200D
             || $cp == 0x2060 || $cp == 0xFEFF;

    # Combining marks (nonspacing + enclosing) stack on the previous glyph.
    return 0 if $ch =~ /\p{Mn}/ || $ch =~ /\p{Me}/;

    # East Asian Wide / Fullwidth glyphs occupy two columns.
    return 2 if $ch =~ /\p{East_Asian_Width=Wide}/
             || $ch =~ /\p{East_Asian_Width=Fullwidth}/;

    return 1;
}

# Strip ANSI escape sequences (CSI/SGR + a conservative OSC sweep) so they do
# not count toward visible width. Mirrors the strippers the components used
# before they delegated here.
sub _strip_ansi {
    my ($s) = @_;
    $s =~ s/\e\[[0-9;?]*[ -\/]*[\@-~]//g;    # CSI ... final
    $s =~ s/\e[\]P_^].*?(?:\e\\|\a)//gs;     # OSC / DCS / APC / PM ... terminator
    return $s;
}

=head2 display_width

    my $cols = display_width($string);

Return the total number of terminal columns C<$string> occupies, summing
C<char_width> over its characters. ANSI escape sequences (SGR colours, cursor
moves, etc.) are stripped first and contribute nothing.

=cut

sub display_width {
    my ($s) = @_;
    return 0 unless defined $s;
    # Fast path: a string of only printable ASCII (no escapes, no wide or
    # zero-width runes) is exactly as many columns as it has characters. This is
    # the overwhelmingly common case (plain log/text lines) and avoids the
    # per-character measurement loop entirely.
    return length $s if $s =~ /\A[\x20-\x7E]*\z/;

    $s = _strip_ansi($s);
    my $w = 0;
    $w += char_width($_) for split //, $s;
    return $w;
}

=head2 truncate_to_width

    my $clipped = truncate_to_width($string, $max_cols);

Return the longest prefix of C<$string> whose display width does not exceed
C<$max_cols>. Embedded ANSI escape sequences are preserved (and do not count
toward the width); a wide glyph that would straddle the limit is dropped whole
rather than split. Combining marks ride along with the glyph they follow.

=cut

sub truncate_to_width {
    my ( $s, $max ) = @_;
    return '' if !defined $s || $max <= 0;

    my @chars = split //, $s;
    my $out   = '';
    my $width = 0;
    my $i     = 0;
    while ( $i < @chars ) {
        my $ch = $chars[$i];
        if ( $ch eq "\e" && $i + 1 < @chars && $chars[ $i + 1 ] eq '[' ) {
            # Copy the whole CSI sequence without counting it.
            my $j = $i + 2;
            $j++ while $j < @chars && $chars[$j] =~ /^[0-9;?]$/;
            $out .= join( '', @chars[ $i .. $j ] ) if $j < @chars;
            $i = $j + 1;
            next;
        }
        my $w = char_width($ch);
        last if $width + $w > $max;
        $out .= $ch;
        $width += $w;
        $i++;
    }
    return $out;
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
