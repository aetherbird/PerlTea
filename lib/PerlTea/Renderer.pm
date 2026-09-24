package PerlTea::Renderer;

use strict;
use warnings;

use PerlTea::Width ();

=head1 NAME

PerlTea::Renderer - diffing terminal renderer for PerlTea

=head1 SYNOPSIS

    my $r = PerlTea::Renderer->new(cols => 80, rows => 24);
    print $r->render("hello\n");
    print $r->render("jello\n"); # emits only the changed cell

=head1 DESCRIPTION

C<PerlTea::Renderer> keeps a cell buffer of the previous frame and emits only
the ANSI bytes needed to transform it into the next frame. It understands ANSI
SGR sequences embedded in the view string, so styled output from
L<PerlTea::Style> diffs correctly: escape sequences do not consume screen cells,
and style changes are detected and re-emitted just like character changes.

Cell placement is East-Asian-aware (see L<PerlTea::Width>): a wide glyph claims
two cells so the buffer's column index always matches the terminal column, and a
combining mark stacks onto the preceding cell instead of taking a column.

=cut

=head2 new

    my $renderer = PerlTea::Renderer->new(cols => 80, rows => 24);

Create a cell-buffer renderer. C<cols> and C<rows> default to 80x24.

=cut

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        cols => $args{cols} || 80,
        rows => $args{rows} || 24,
        frame => undef,
        attr  => '',    # last emitted SGR attribute string
    };
    return bless $self, $class;
}

=head2 resize

    $renderer->resize(cols => 100, rows => 30);

Set the render size and invalidate the previous frame so the next render repaints
the visible area.

=cut

sub resize {
    my ( $self, %args ) = @_;
    $self->{cols}  = $args{cols} if $args{cols};
    $self->{rows}  = $args{rows} if $args{rows};
    $self->{frame} = undef;
    return;
}

=head2 render

    my $bytes = $renderer->render($view);

Render C<$view> into the current cell buffer and return only the ANSI bytes needed
to transform the previous frame into the new one.

=cut

sub render {
    my ( $self, $view ) = @_;
    $view = '' unless defined $view;

    my $next = $self->_frame_from($view);
    my $prev = $self->{frame};
    my $out  = '';

    if ( !defined $prev ) {
        $out .= "\e[2J\e[H";
        my $current_attr = '';
        for my $row ( 0 .. $#{ $next } ) {
            my ( $line_out, $line_attr ) = ( '', '' );
            for my $col ( 0 .. $#{ $next->[$row] } ) {
                my ( $ch, $attr ) = @{ $next->[$row][$col] };
                if ( $attr ne $line_attr ) {
                    $line_out .= ( $attr eq '' ? "\e[0m" : "\e[0m" . $attr );
                    $line_attr = $attr;
                }
                $line_out .= $ch unless $ch eq "\0";    # wide-glyph continuation
            }
            # Leave each line in the default attribute so trailing cells are not
            # unexpectedly styled if the cursor later lands on them.
            if ( $line_attr ne '' ) {
                $line_out .= "\e[0m";
                $line_attr = '';
            }
            $line_out =~ s/[ ]+\z//;
            next if $line_out eq '';
            $out .= _cursor( $row, 0 ) . $line_out;
            $current_attr = $line_attr;
        }
        $self->{attr} = $current_attr;
    }
    else {
        my $current_attr = $self->{attr} // '';
        for my $row ( 0 .. $#{ $next } ) {
            my $col = 0;
            while ( $col < $self->{cols} ) {
                my ( $nch, $nattr ) = @{ $next->[$row][$col] };
                my ( $pch, $pattr ) = @{ $prev->[$row][$col] };
                if ( $nch eq $pch && $nattr eq $pattr ) {
                    $col++;
                    next;
                }

                my $start    = $col;
                my $run_out  = '';
                my $run_attr = $current_attr;
                while ( $col < $self->{cols} ) {
                    my ( $cch, $cattr ) = @{ $next->[$row][$col] };
                    my ( $pcch, $pcattr ) = @{ $prev->[$row][$col] };
                    last if $cch eq $pcch && $cattr eq $pcattr;

                    if ( $cattr ne $run_attr ) {
                        $run_out .= ( $cattr eq '' ? "\e[0m" : "\e[0m" . $cattr );
                        $run_attr = $cattr;
                    }
                    $run_out .= $cch unless $cch eq "\0";    # wide-glyph continuation
                    $col++;
                }

                $out .= _cursor( $row, $start ) . $run_out;
                $current_attr = $run_attr;
            }
        }
        $self->{attr} = $current_attr;
    }

    $self->{frame} = $next;
    return $out;
}

# Build a frame from a view string. Each cell is [char, sgr_attr] where sgr_attr
# is the absolute ANSI SGR prefix needed to draw that character from a default
# state. ANSI escape sequences in the input are parsed and tracked; they do not
# become visible cells.
sub _frame_from {
    my ( $self, $view ) = @_;
    my @input = split /\n/, $view, -1;
    pop @input if @input && $input[-1] eq '';

    my @frame;
    my $state = {};
    for my $row ( 0 .. $self->{rows} - 1 ) {
        my @cells;
        my $line = $input[$row] // '';
        my @chars = split //, $line;
        my $col = 0;
        my $i   = 0;
        while ( $i < @chars && $col < $self->{cols} ) {
            my $ch = $chars[$i];
            if ( $ch eq "\e" && $i + 1 < @chars && $chars[ $i + 1 ] eq '[' ) {
                # CSI sequence: consume parameter bytes, then intermediate bytes,
                # then the final byte.
                my $j = $i + 2;
                $j++ while $j < @chars && ord( $chars[$j] ) >= 0x30 && ord( $chars[$j] ) <= 0x3F;
                $j++ while $j < @chars && ord( $chars[$j] ) >= 0x20 && ord( $chars[$j] ) <= 0x2F;
                my $final = $chars[$j];
                if ( defined $final && ord($final) >= 0x40 && ord($final) <= 0x7E ) {
                    if ( $final eq 'm' ) {
                        my $params = join( '', @chars[ $i + 2 .. $j - 1 ] );
                        $params =~ s/^\?//;    # drop private marker if any
                        my @codes = ( $params eq '' ) ? (0) : split /;/, $params;
                        _apply_sgr( \@codes, $state );
                    }
                    $i = $j + 1;
                    next;
                }
            }

            # Width-aware cell placement: a wide glyph claims two cells (the
            # second is an empty continuation so array index == terminal
            # column); a combining/zero-width mark stacks onto the previous
            # cell instead of taking a column of its own.
            my $w = PerlTea::Width::char_width($ch);
            if ( $w == 0 ) {
                $cells[-1][0] .= $ch if @cells;
                $i++;
                next;
            }
            if ( $w == 2 ) {
                if ( $col + 2 > $self->{cols} ) {
                    # No room for both halves: pad the last column and drop it.
                    push @cells, [ ' ', _attr_from_state($state) ];
                    $col++;
                    $i++;
                    next;
                }
                my $attr = _attr_from_state($state);
                push @cells, [ $ch, $attr ];
                push @cells, [ "\0", $attr ];    # continuation (emits nothing)
                $col += 2;
                $i++;
                next;
            }

            push @cells, [ $ch, _attr_from_state($state) ];
            $col++;
            $i++;
        }

        while ( @cells < $self->{cols} ) {
            push @cells, [ ' ', '' ];
        }
        push @frame, \@cells;
    }
    return \@frame;
}

sub _apply_sgr {
    my ( $codes, $state ) = @_;
    my $i = 0;
    while ( $i < @$codes ) {
        my $c = int( $codes->[$i] );
        if    ( $c == 0 )  { %$state = (); }
        elsif ( $c == 1 )  { $state->{bold} = 1; }
        elsif ( $c == 2 )  { $state->{faint} = 1; }
        elsif ( $c == 3 )  { $state->{italic} = 1; }
        elsif ( $c == 4 )  { $state->{underline} = 1; }
        elsif ( $c == 5 )  { $state->{blink} = 1; }
        elsif ( $c == 7 )  { $state->{reverse} = 1; }
        elsif ( $c == 9 )  { $state->{strike} = 1; }
        elsif ( $c == 22 ) { delete $state->{bold}; delete $state->{faint}; }
        elsif ( $c == 23 ) { delete $state->{italic}; }
        elsif ( $c == 24 ) { delete $state->{underline}; }
        elsif ( $c == 25 ) { delete $state->{blink}; }
        elsif ( $c == 27 ) { delete $state->{reverse}; }
        elsif ( $c == 29 ) { delete $state->{strike}; }
        elsif ( $c >= 30 && $c <= 37 ) { $state->{fg} = { mode => '16', code => $c }; }
        elsif ( $c == 38 ) {
            my $mode = int( $codes->[ ++$i ] // 0 );
            if ( $mode == 2 ) {
                $state->{fg} = { mode => 'true', r => int( $codes->[++$i] // 0 ), g => int( $codes->[++$i] // 0 ), b => int( $codes->[++$i] // 0 ) };
            }
            elsif ( $mode == 5 ) {
                $state->{fg} = { mode => '256', code => int( $codes->[++$i] // 0 ) };
            }
        }
        elsif ( $c == 39 ) { delete $state->{fg}; }
        elsif ( $c >= 40 && $c <= 47 ) { $state->{bg} = { mode => '16', code => $c }; }
        elsif ( $c == 48 ) {
            my $mode = int( $codes->[ ++$i ] // 0 );
            if ( $mode == 2 ) {
                $state->{bg} = { mode => 'true', r => int( $codes->[++$i] // 0 ), g => int( $codes->[++$i] // 0 ), b => int( $codes->[++$i] // 0 ) };
            }
            elsif ( $mode == 5 ) {
                $state->{bg} = { mode => '256', code => int( $codes->[++$i] // 0 ) };
            }
        }
        elsif ( $c == 49 ) { delete $state->{bg}; }
        elsif ( $c >= 90 && $c <= 97 )  { $state->{fg} = { mode => '16', code => $c }; }
        elsif ( $c >= 100 && $c <= 107 ){ $state->{bg} = { mode => '16', code => $c }; }
        $i++;
    }
}

sub _attr_from_state {
    my ($state) = @_;
    my @codes;
    push @codes, 1 if $state->{bold};
    push @codes, 2 if $state->{faint};
    push @codes, 3 if $state->{italic};
    push @codes, 4 if $state->{underline};
    push @codes, 5 if $state->{blink};
    push @codes, 7 if $state->{reverse};
    push @codes, 9 if $state->{strike};

    if ( $state->{fg} ) {
        my $f = $state->{fg};
        if    ( $f->{mode} eq '16' )  { push @codes, $f->{code}; }
        elsif ( $f->{mode} eq '256' ) { push @codes, 38, 5, $f->{code}; }
        elsif ( $f->{mode} eq 'true' ) { push @codes, 38, 2, $f->{r}, $f->{g}, $f->{b}; }
    }
    if ( $state->{bg} ) {
        my $b = $state->{bg};
        if    ( $b->{mode} eq '16' )  { push @codes, $b->{code}; }
        elsif ( $b->{mode} eq '256' ) { push @codes, 48, 5, $b->{code}; }
        elsif ( $b->{mode} eq 'true' ) { push @codes, 48, 2, $b->{r}, $b->{g}, $b->{b}; }
    }

    return @codes ? "\e[" . join( ';', @codes ) . 'm' : '';
}

=head2 display_width

    my $cols = PerlTea::Renderer::display_width($string);

Return the East-Asian-aware display width of C<$string> in terminal columns,
ignoring any embedded ANSI escape sequences. This is the width the renderer uses
when laying characters into cells; it is a thin delegate to
L<PerlTea::Width/display_width> so callers can reach it through the renderer.

=cut

sub display_width {
    my ($s) = @_;
    return PerlTea::Width::display_width($s);
}

sub _cursor {
    my ( $row, $col ) = @_;
    return "\e[" . ( $row + 1 ) . ';' . ( $col + 1 ) . 'H';
}

1;
