package PerlTea::Style;

use strict;
use warnings;

use PerlTea::Width ();

=head1 NAME

PerlTea::Style - declarative styling for PerlTea (colors, borders, padding,
alignment, text attributes)

=head1 SYNOPSIS

    use PerlTea::Style;

    my $box = PerlTea::Style->new(
        border     => 'single',
        padding    => [1, 2],
        width      => 40,
        height     => 8,
        align      => 'center',
        foreground => '#e0e0e0',
        background => '#2a0a4a',
        bold       => 1,
    );

    print $box->render("Hello, PerlTea!");

=head1 DESCRIPTION

C<PerlTea::Style> is a Lip Gloss–style declarative styling layer. A style
describes border, padding, margins, size, alignment, foreground/background
color, and text attributes. Calling C<render($text)> applies the style and
returns a string containing the visible characters plus the ANSI SGR sequences
needed to draw them.

Colors may be specified as:

=over 4

=item * named 16-color strings such as C<red>, C<bright-blue>, C<white>, C<black>

=item * integers C<0-255> for the 256-color palette

=item * hex strings such as C<#ff5733> for 24-bit truecolor

=item * hashrefs C<< { r => 255, g => 87, b => 51 } >>

=back

The active color profile is chosen at construction time:

=over 4

=item * C<PERLTEA_FORCE_COLORS=16> forces 16-color mode

=item * C<COLORTERM=truecolor> or C<COLORTERM=24bit> selects truecolor

=item * C<TERM=...256color...> selects 256-color mode

=item * otherwise 16-color mode is used

=back

=cut

# Standard 16-color palette (RGB values for downgrade mapping).
my @ANSI16 = (
    [ 0,   0,   0   ],    # 30 black
    [ 128, 0,   0   ],    # 31 red
    [ 0,   128, 0   ],    # 32 green
    [ 128, 128, 0   ],    # 33 yellow
    [ 0,   0,   128 ],    # 34 blue
    [ 128, 0,   128 ],    # 35 magenta
    [ 0,   128, 128 ],    # 36 cyan
    [ 192, 192, 192 ],    # 37 white
    [ 128, 128, 128 ],    # 90 bright black
    [ 255, 0,   0   ],    # 91 bright red
    [ 0,   255, 0   ],    # 92 bright green
    [ 255, 255, 0   ],    # 93 bright yellow
    [ 0,   0,   255 ],    # 94 bright blue
    [ 255, 0,   255 ],    # 95 bright magenta
    [ 0,   255, 255 ],    # 96 bright cyan
    [ 255, 255, 255 ],    # 97 bright white
);

my %NAMED16 = (
    'black'         => 30, 'red'           => 31, 'green'         => 32,
    'yellow'        => 33, 'blue'          => 34, 'magenta'       => 35,
    'cyan'          => 36, 'white'         => 37,
    'bright-black'  => 90, 'bright-red'    => 91, 'bright-green'  => 92,
    'bright-yellow' => 93, 'bright-blue'   => 94, 'bright-magenta'=> 95,
    'bright-cyan'   => 96, 'bright-white'  => 97,
    'grey'          => 90, 'gray'          => 90,
);

# Box-drawing characters for supported border styles.
my %BORDERS = (
    single => {
        tl => "\x{250c}", tr => "\x{2510}", bl => "\x{2514}", br => "\x{2518}",
        h  => "\x{2500}", v  => "\x{2502}",
    },
    rounded => {
        tl => "\x{256d}", tr => "\x{256e}", bl => "\x{2570}", br => "\x{256f}",
        h  => "\x{2500}", v  => "\x{2502}",
    },
    double => {
        tl => "\x{2554}", tr => "\x{2557}", bl => "\x{255a}", br => "\x{255d}",
        h  => "\x{2550}", v  => "\x{2551}",
    },
    none => undef,
);

=head2 new

    my $style = PerlTea::Style->new(%properties);

Create a new style. Properties:

=over 4

=item * C<border> - C<single>, C<rounded>, C<double>, or C<none> (default C<none>)

=item * C<padding> - scalar, or arrayref C<[vertical, horizontal]>,
                     or arrayref C<[top, right, bottom, left]>

=item * C<margin>  - same forms as C<padding>

=item * C<width>   - total interior width (including padding, excluding border/margin)

=item * C<height>  - total interior height (including padding, excluding border/margin)

=item * C<align>   - C<left>, C<center>, or C<right>

=item * C<vertical_align> - C<top>, C<center>/C<middle>, or C<bottom>

=item * C<foreground> / C<background> - color spec

=item * C<bold>, C<italic>, C<underline>, C<faint>, C<blink>, C<reverse>, C<strike>
       - boolean text attributes

=item * C<color_profile> - C<16>, C<256>, or C<truecolor>; overrides environment

=back

=cut

sub new {
    my ( $class, %args ) = @_;

    my $self = {
        border         => $args{border}         || 'none',
        width          => $args{width}          || 0,
        height         => $args{height}         || 0,
        align          => $args{align}          || 'left',
        vertical_align => $args{vertical_align} || 'top',
        foreground     => $args{foreground},
        background     => $args{background},
        bold           => $args{bold}      ? 1 : 0,
        italic         => $args{italic}    ? 1 : 0,
        underline      => $args{underline} ? 1 : 0,
        faint          => $args{faint}     ? 1 : 0,
        blink          => $args{blink}     ? 1 : 0,
        reverse        => $args{reverse}   ? 1 : 0,
        strike         => $args{strike}    ? 1 : 0,
    };

    $self->{padding} = _normalize_inset( $args{padding} );
    $self->{margin}  = _normalize_inset( $args{margin} );

    $self->{color_profile}
        = $args{color_profile}
        ? lc( $args{color_profile} )
        : _detect_color_profile();

    return bless $self, $class;
}

sub _normalize_inset {
    my ($v) = @_;
    return [ 0, 0, 0, 0 ] unless defined $v;
    if ( !ref $v ) {
        return [ $v + 0, $v + 0, $v + 0, $v + 0 ];
    }
    if ( ref $v eq 'ARRAY' ) {
        if ( @$v == 1 ) { return [ $v->[0], $v->[0], $v->[0], $v->[0] ]; }
        if ( @$v == 2 ) { return [ $v->[0], $v->[1], $v->[0], $v->[1] ]; }
        if ( @$v >= 4 ) { return [ $v->[0], $v->[1], $v->[2], $v->[3] ]; }
    }
    return [ 0, 0, 0, 0 ];
}

sub _detect_color_profile {
    return '16' if ( $ENV{PERLTEA_FORCE_COLORS} // '' ) eq '16';
    my $ct = lc( $ENV{COLORTERM} // '' );
    return 'truecolor' if $ct eq 'truecolor' || $ct eq '24bit';
    my $term = lc( $ENV{TERM} // '' );
    return '256'     if $term =~ /256/;
    return 'truecolor' if $term =~ /truecolor|24bit/;
    return '16';
}

=head2 color_profile

    my $profile = $style->color_profile;

Return the active color profile: C<16>, C<256>, or C<truecolor>.

=cut

sub color_profile { return $_[0]->{color_profile} }

# Parse a color spec into an internal {mode, ...} record.
sub _parse_color {
    my ( $self, $spec ) = @_;
    return undef unless defined $spec;

    if ( !ref $spec ) {
        my $s = lc $spec;
        $s =~ s/\s+/-/g;
        if ( exists $NAMED16{$s} ) {
            return { mode => '16', code => $NAMED16{$s} };
        }
        if ( $s =~ /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/ ) {
            return { mode => 'true', r => hex($1), g => hex($2), b => hex($3) };
        }
        if ( $s =~ /^(\d+)$/ && $1 >= 0 && $1 <= 255 ) {
            return { mode => '256', code => int($1) };
        }
        return undef;
    }

    if ( ref $spec eq 'HASH' ) {
        return {
            mode => 'true',
            r    => int( $spec->{r} // 0 ),
            g    => int( $spec->{g} // 0 ),
            b    => int( $spec->{b} // 0 ),
        };
    }

    return undef;
}

# Return the SGR parameter numbers for a color under the active profile.
sub _color_codes {
    my ( $self, $color, $bg ) = @_;
    return () unless $color;

    my $profile = $self->{color_profile};

    if ( $profile eq 'truecolor' ) {
        if ( $color->{mode} eq '16' ) {
            my $code = $color->{code};
            $code += 10 if $bg;
            return ( $code );
        }
        if ( $color->{mode} eq '256' ) {
            return ( $bg ? 48 : 38, 5, $color->{code} );
        }
        return ( $bg ? 48 : 38, 2, $color->{r}, $color->{g}, $color->{b} );
    }

    if ( $profile eq '256' ) {
        if ( $color->{mode} eq '16' ) {
            my $code = $color->{code};
            $code += 10 if $bg;
            return ( $code );
        }
        my ( $r, $g, $b );
        if ( $color->{mode} eq '256' ) {
            ( $r, $g, $b ) = _idx256_to_rgb( $color->{code} );
        }
        else {
            ( $r, $g, $b ) = @$color{qw(r g b)};
        }
        my $idx = _rgb_to_idx256( $r, $g, $b );
        return ( $bg ? 48 : 38, 5, $idx );
    }

    # 16-color mode: everything collapses to the nearest ANSI 16 color.
    my ( $r, $g, $b );
    if ( $color->{mode} eq '16' ) {
        my $idx = $color->{code} - 30;
        $idx -= 52 if $idx >= 60;    # 90..97 -> 8..15
        ( $r, $g, $b ) = @{ $ANSI16[$idx] };
    }
    elsif ( $color->{mode} eq '256' ) {
        ( $r, $g, $b ) = _idx256_to_rgb( $color->{code} );
    }
    else {
        ( $r, $g, $b ) = @$color{qw(r g b)};
    }

    my $code = _nearest_ansi16( $r, $g, $b );
    $code += 10 if $bg;
    return ( $code );
}

# Convert an internal color to the active profile, returning a raw escape sequence.
sub _emit_color {
    my ( $self, $color, $bg ) = @_;
    my @codes = _color_codes( $self, $color, $bg );
    return @codes ? "\e[" . join( ';', @codes ) . 'm' : '';
}

sub _idx256_to_rgb {
    my ($idx) = @_;
    if ( $idx >= 232 ) {
        my $lvl = 8 + ( $idx - 232 ) * 10;
        $lvl = 255 if $lvl > 255;
        return ( $lvl, $lvl, $lvl );
    }
    my $i = $idx - 16;
    my $b = ( $i % 6 ) * 40 + ( $i % 6 ? 55 : 0 );
    $i = int( $i / 6 );
    my $g = ( $i % 6 ) * 40 + ( $i % 6 ? 55 : 0 );
    $i = int( $i / 6 );
    my $r = ( $i % 6 ) * 40 + ( $i % 6 ? 55 : 0 );
    return ( $r, $g, $b );
}

sub _rgb_to_idx256 {
    my ( $r, $g, $b ) = @_;
    if ( $r == $g && $g == $b ) {
        return 232 if $r < 8;
        return 255 if $r > 247;
        return 232 + int( ( $r - 8 ) / 10 );
    }
    my $ri = $r >= 55 ? int( ( $r - 35 ) / 40 ) : 0; $ri = 5 if $ri > 5;
    my $gi = $g >= 55 ? int( ( $g - 35 ) / 40 ) : 0; $gi = 5 if $gi > 5;
    my $bi = $b >= 55 ? int( ( $b - 35 ) / 40 ) : 0; $bi = 5 if $bi > 5;
    return 16 + 36 * $ri + 6 * $gi + $bi;
}

sub _nearest_ansi16 {
    my ( $r, $g, $b ) = @_;
    my $best = 0;
    my $best_d = 1e9;
    for my $i ( 0 .. $#ANSI16 ) {
        my $d = ( $r - $ANSI16[$i][0] )**2
              + ( $g - $ANSI16[$i][1] )**2
              + ( $b - $ANSI16[$i][2] )**2;
        if ( $d < $best_d ) {
            $best_d = $d;
            $best   = $i;
        }
    }
    return $best < 8 ? $best + 30 : $best + 82;    # 8..15 -> 90..97
}

# Build the SGR prefix for this style (no reset).
sub _sgr {
    my ($self) = @_;
    my @codes;
    push @codes, 1 if $self->{bold};
    push @codes, 2 if $self->{faint};
    push @codes, 3 if $self->{italic};
    push @codes, 4 if $self->{underline};
    push @codes, 5 if $self->{blink};
    push @codes, 7 if $self->{reverse};
    push @codes, 9 if $self->{strike};

    my $fg = _parse_color( $self, $self->{foreground} );
    my $bg = _parse_color( $self, $self->{background} );
    push @codes, _color_codes( $self, $fg, 0 ) if $fg;
    push @codes, _color_codes( $self, $bg, 1 ) if $bg;

    return @codes ? "\e[" . join( ';', @codes ) . 'm' : '';
}

=head2 render

    my $styled = $style->render($text);

Apply the style to C<$text> and return the resulting string. C<$text> may
contain newlines; each line is aligned independently inside the content area.

=cut

sub render {
    my ( $self, $text ) = @_;
    $text = '' unless defined $text;

    my $border = $BORDERS{ $self->{border} };
    my $has_border = defined $border;

    my @lines = split /\r?\n/, $text, -1;
    pop @lines if @lines && $lines[-1] eq '';

    # Visible content dimensions (text only, before padding).
    my $content_width = 0;
    for my $line (@lines) {
        my $len = _visible_length($line);
        $content_width = $len if $len > $content_width;
    }

    my $pad = $self->{padding};
    my $mar = $self->{margin};

    # Interior width including padding. If the user did not supply a width,
    # size to the content plus padding plus border.
    my $inner_width = $self->{width} || ( $content_width + $pad->[1] + $pad->[3] );
    my $inner_height = $self->{height} || ( scalar(@lines) + $pad->[0] + $pad->[2] );

    # Add border thickness if present.
    my $box_width  = $inner_width + ( $has_border ? 2 : 0 );
    my $box_height = $inner_height + ( $has_border ? 2 : 0 );

    # Content area dimensions inside padding.
    my $content_cols = $inner_width - $pad->[1] - $pad->[3];
    $content_cols = 0 if $content_cols < 0;
    my $content_rows = $inner_height - $pad->[0] - $pad->[2];
    $content_rows = 0 if $content_rows < 0;

    # Truncate/pad content lines to fit content_cols.
    for my $line (@lines) {
        $line = _truncate_visible( $line, $content_cols );
    }

    # Vertical alignment of the text block inside the content area.
    my $top_pad = _v_align_offset( scalar(@lines), $content_rows, $self->{vertical_align} );
    my @content_area;
    push @content_area, '' for 1 .. $top_pad;
    push @content_area, @lines;
    while ( @content_area < $content_rows ) {
        push @content_area, '';
    }

    # Build the styled box one physical row at a time.
    my $sgr  = $self->_sgr;
    my $reset = "\e[0m";

    my @rows;

    # Top margin.
    push @rows, '' for 1 .. $mar->[0];

    # Top border (if any).
    if ($has_border) {
        my $margin_left = ' ' x $mar->[3];
        push @rows,
              $margin_left
            . $border->{tl}
            . ( $border->{h} x ( $box_width - 2 ) )
            . $border->{tr};
    }

    # Interior rows: left margin + left border + padding + content + padding +
    # right border + right margin. We apply the style to the whole interior
    # (padding + content) so the background color fills the box.
    for my $r ( 0 .. $inner_height - 1 ) {
        my $margin_left = ' ' x $mar->[3];
        my $row = $margin_left;
        $row .= $border->{v} if $has_border;

        # Inside the border we have: left padding + content line + right padding.
        my $content_idx = $r - $pad->[0];
        my $content_line = ( $content_idx >= 0 && $content_idx < @content_area )
            ? $content_area[$content_idx]
            : '';
        my $aligned = _align_line( $content_line, $content_cols, $self->{align} );

        my $interior = ( ' ' x $pad->[3] ) . $aligned . ( ' ' x $pad->[1] );
        # Apply style (background fills the interior).
        $row .= $sgr . $interior . $reset if $sgr;
        $row .= $interior                 if !$sgr;

        $row .= $border->{v} if $has_border;
        push @rows, $row;
    }

    # Bottom border (if any).
    if ($has_border) {
        my $margin_left = ' ' x $mar->[3];
        push @rows,
              $margin_left
            . $border->{bl}
            . ( $border->{h} x ( $box_width - 2 ) )
            . $border->{br};
    }

    # Bottom margin.
    push @rows, '' for 1 .. $mar->[2];

    return join( "\n", @rows );
}

# Visible display width: East-Asian-aware, ANSI escapes ignored (see PerlTea::Width).
sub _visible_length {
    my ($s) = @_;
    return PerlTea::Width::display_width($s);
}

sub _truncate_visible {
    my ( $s, $max ) = @_;
    return PerlTea::Width::truncate_to_width( $s, $max );
}

sub _align_line {
    my ( $line, $width, $align ) = @_;
    my $len = _visible_length($line);
    my $pad = $width - $len;
    $pad = 0 if $pad < 0;

    if ( $align eq 'right' ) {
        return ( ' ' x $pad ) . $line;
    }
    if ( $align eq 'center' ) {
        my $left = int( $pad / 2 );
        return ( ' ' x $left ) . $line . ( ' ' x ( $pad - $left ) );
    }
    return $line . ( ' ' x $pad );
}

sub _v_align_offset {
    my ( $content_h, $area_h, $align ) = @_;
    return 0 if $content_h >= $area_h;
    if ( $align eq 'bottom' ) {
        return $area_h - $content_h;
    }
    if ( $align eq 'center' || $align eq 'middle' ) {
        return int( ( $area_h - $content_h ) / 2 );
    }
    return 0;
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
