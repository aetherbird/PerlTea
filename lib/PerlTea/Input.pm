package PerlTea::Input;

use strict;
use warnings;
use Encode qw(FB_CROAK decode);

=head1 NAME

PerlTea::Input - terminal input decoder for PerlTea

=head1 SYNOPSIS

    use PerlTea::Input;
    my $dec = PerlTea::Input->new;
    my @msgs = $dec->feed($raw_bytes);

=head1 DESCRIPTION

Decodes the byte stream produced by a terminal in raw mode into typed messages.
Single-byte controls, UTF-8 printable characters, CSI / SS3 escape sequences
(arrows, function keys, modifiers), and bracketed paste are supported. The
decoder is stateful so sequences that arrive across multiple C<read> calls are
still reassembled.

=cut

=head2 new

    my $decoder = PerlTea::Input->new;

Create a fresh input decoder.

=cut

sub new {
    my ($class) = @_;
    return bless {
        buf            => '',
        paste_state    => 0,
        paste_buf      => '',
        paste_start_raw => '',
    }, $class;
}

=head2 feed

    my @messages = $decoder->feed($bytes);

Consume a raw byte chunk and return zero or more input messages. Incomplete
escape sequences are held in the decoder's buffer until the next call.

Each message is a hash reference:

    # ordinary key
    { type => 'key', key => 'up', rune => '', raw => "\e[A" }

    # printable key
    { type => 'key', key => 'a',  rune => 'a', raw => 'a' }

    # bracketed paste
    { type => 'paste', text => 'hello', raw => "\e[200~hello\e[201~" }

=cut

sub feed {
    my ( $self, $bytes ) = @_;
    $self->{buf} .= $bytes;
    my @msgs;
    while (1) {
        my $msg = $self->_decode_one;
        last unless defined $msg;
        push @msgs, $msg;
    }
    return @msgs;
}

# Consume one message from the buffer, or return undef if more bytes are needed.
sub _decode_one {
    my ($self) = @_;

    # Bracketed paste mode: collect everything until the closing sequence.
    if ( $self->{paste_state} ) {
        my $buf = $self->{buf};
        my $end = index( $buf, "\e[201~" );
        if ( $end >= 0 ) {
            my $tail = substr( $buf, 0, $end );
            my $text = $self->{paste_buf} . $tail;
            $self->{buf} = substr( $buf, $end + length("\e[201~") );
            $self->{paste_state} = 0;
            my $raw = $self->{paste_start_raw} . $self->{paste_buf} . $tail . "\e[201~";
            return { type => 'paste', text => $text, raw => $raw };
        }
        $self->{paste_buf} .= $buf;
        $self->{buf} = '';
        return undef;
    }

    return undef if $self->{buf} eq '';

    my $lead = substr( $self->{buf}, 0, 1 );
    if ( $lead eq "\e" ) {
        return $self->_decode_escape;
    }

    return $self->_decode_single_byte;
}

# Decode a lone byte (control or printable).
sub _decode_single_byte {
    my ($self) = @_;
    my $b = substr( $self->{buf}, 0, 1 );
    my $ord = ord($b);

    # Control characters.
    if ( $ord == 0 ) {
        $self->{buf} = substr( $self->{buf}, 1 );
        return { type => 'key', key => 'ctrl+space', rune => $b, raw => $b };
    }
    elsif ( $ord == 9 ) {
        $self->{buf} = substr( $self->{buf}, 1 );
        return { type => 'key', key => 'tab',        rune => $b, raw => $b };
    }
    elsif ( $ord == 13 ) {
        $self->{buf} = substr( $self->{buf}, 1 );
        return { type => 'key', key => 'enter',      rune => $b, raw => $b };
    }
    elsif ( $ord == 27 ) {
        $self->{buf} = substr( $self->{buf}, 1 );
        return { type => 'key', key => 'esc',        rune => $b, raw => $b };
    }
    elsif ( $ord == 32 ) {
        $self->{buf} = substr( $self->{buf}, 1 );
        return { type => 'key', key => 'space',      rune => $b, raw => $b };
    }
    elsif ( $ord == 127 ) {
        $self->{buf} = substr( $self->{buf}, 1 );
        return { type => 'key', key => 'backspace',  rune => $b, raw => $b };
    }
    elsif ( $ord >= 1 && $ord <= 26 ) {
        my $letter = chr( $ord + 96 );
        $self->{buf} = substr( $self->{buf}, 1 );
        return { type => 'key', key => "ctrl+$letter", rune => $b, raw => $b };
    }

    # Printable UTF-8 character. ASCII still consumes one byte; multi-byte
    # sequences wait in the buffer until all continuation bytes have arrived.
    return $self->_decode_printable_utf8;
}

sub _decode_printable_utf8 {
    my ($self) = @_;
    my $buf = $self->{buf};
    my $lead = ord( substr( $buf, 0, 1 ) );
    my $need;

    if ( $lead < 0x80 ) {
        $need = 1;
    }
    elsif ( $lead >= 0xC2 && $lead <= 0xDF ) {
        $need = 2;
    }
    elsif ( $lead >= 0xE0 && $lead <= 0xEF ) {
        $need = 3;
    }
    elsif ( $lead >= 0xF0 && $lead <= 0xF4 ) {
        $need = 4;
    }
    else {
        # Malformed high-bit lead byte: consume it so the decoder cannot wedge.
        $need = 1;
    }

    return undef if length($buf) < $need;

    my $raw = substr( $buf, 0, $need );
    $self->{buf} = substr( $buf, $need );
    my $rune = _decode_utf8_or_raw($raw);
    return { type => 'key', key => $rune, rune => $rune, raw => $raw };
}

# Decode an escape sequence (CSI, SS3, or alt+key).
sub _decode_escape {
    my ($self) = @_;
    my $buf = $self->{buf};

    # Bracketed paste start.
    if ( $buf =~ /^\e\[200~/ ) {
        $self->{paste_state}     = 1;
        $self->{paste_buf}       = '';
        $self->{paste_start_raw} = "\e[200~";
        $self->{buf}             = substr( $buf, length("\e[200~") );
        return $self->_decode_one;
    }

    # CSI: ESC [ params final.
    if ( $buf =~ /^\e\[/ ) {
        return $self->_decode_csi;
    }

    # SS3: ESC O final (arrows and F1-F4 in some terminals).
    if ( $buf =~ /^\eO/ ) {
        return $self->_decode_ss3;
    }

    # Lone ESC, or one more byte for alt+key.
    if ( length($buf) < 2 ) {
        $self->{buf} = '';
        return { type => 'key', key => 'esc', rune => "\e", raw => "\e" };
    }

    my $rest = substr( $buf, 1, 1 );
    if ( ord($rest) >= 0x80 ) {
        my $lead = ord($rest);
        my $need =
              ( $lead >= 0xC2 && $lead <= 0xDF ) ? 2
            : ( $lead >= 0xE0 && $lead <= 0xEF ) ? 3
            : ( $lead >= 0xF0 && $lead <= 0xF4 ) ? 4
            : 1;
        return undef if length($buf) < 1 + $need;
        my $raw_key = substr( $buf, 1, $need );
        my $rune    = _decode_utf8_or_raw($raw_key);
        $self->{buf} = substr( $buf, 1 + $need );
        return { type => 'key', key => "alt+$rune", rune => $rune, raw => substr( $buf, 0, 1 + $need ) };
    }

    $self->{buf} = substr( $buf, 2 );
    return { type => 'key', key => "alt+$rest", rune => $rest, raw => substr( $buf, 0, 2 ) };
}

sub _decode_utf8_or_raw {
    my ($raw) = @_;
    my $decoded = eval { decode( 'UTF-8', $raw, FB_CROAK ) };
    return defined $decoded ? $decoded : $raw;
}

# Match and parse a CSI sequence.
sub _decode_csi {
    my ($self) = @_;
    my $buf = $self->{buf};

    # CSI sequences: ESC [ followed by parameter bytes (0x30-0x3F),
    # optional intermediate bytes (0x20-0x2F), then a final byte (0x40-0x7E).
    if ( $buf =~ /^\e\[[\x30-\x3F]*[\x20-\x2F]*[\x40-\x7E]/ ) {
        my $seq = $&;
        $self->{buf} = substr( $buf, length($seq) );
        return $self->_parse_csi($seq);
    }

    # Incomplete CSI: wait for more bytes.
    return undef;
}

sub _parse_csi {
    my ( $self, $seq ) = @_;

    # Strip ESC [ prefix; the rest is params + final byte.
    my $inner = substr( $seq, 2 );
    my $final = substr( $inner, -1, 1 );
    my $param = substr( $inner, 0, -1 );

    my @p = split /;/, $param;
    my $p1 = $p[0] // '';

    # Modifier is the second parameter when present. For tilde keys the first
    # parameter is the key number, so a lone parameter is never a modifier.
    # For letter finals (A/B/C/D/H/F) a lone non-1 parameter is treated as the
    # modifier encoding to tolerate terminals that omit the placeholder 1.
    my $modifier = '';
    if ( @p > 1 ) {
        $modifier = $p[-1];
    }
    elsif ( @p == 1 && $final =~ /^[ABCDHF]$/ && $p1 ne '' && $p1 ne '1' ) {
        $modifier = $p1;
    }

    my $prefix = '';
    if ( defined $modifier && $modifier =~ /^[2-8]$/ ) {
        my $bits = $modifier - 1;
        my @mods;
        push @mods, 'shift' if $bits & 1;
        push @mods, 'alt'   if $bits & 2;
        push @mods, 'ctrl'  if $bits & 4;
        $prefix = join( '+', @mods ) . '+' if @mods;
    }

    my %csi_letter = (
        'A' => 'up',
        'B' => 'down',
        'C' => 'right',
        'D' => 'left',
        'H' => 'home',
        'F' => 'end',
        'Z' => 'shift+tab',
    );

    if ( exists $csi_letter{$final} ) {
        my $key = $csi_letter{$final};
        return { type => 'key', key => $prefix . $key, rune => '', raw => $seq };
    }

    if ( $final eq '~' ) {
        my %tilde = (
            1  => 'home',
            2  => 'insert',
            3  => 'delete',
            4  => 'end',
            5  => 'pgup',
            6  => 'pgdown',
            7  => 'home',
            8  => 'end',
            11 => 'f1',
            12 => 'f2',
            13 => 'f3',
            14 => 'f4',
            15 => 'f5',
            17 => 'f6',
            18 => 'f7',
            19 => 'f8',
            20 => 'f9',
            21 => 'f10',
            23 => 'f11',
            24 => 'f12',
        );
        my $key = $tilde{$p1} // "csi~$p1";
        return { type => 'key', key => $prefix . $key, rune => '', raw => $seq };
    }

    return { type => 'key', key => "csi:$inner", rune => '', raw => $seq };
}

# Match and parse an SS3 sequence (ESC O final).
sub _decode_ss3 {
    my ($self) = @_;
    my $buf = $self->{buf};

    if ( $buf =~ /^\eO[\x20-\x2F]*[\x40-\x7E]/ ) {
        my $seq   = $&;
        my $final = substr( $seq, -1, 1 );
        $self->{buf} = substr( $buf, length($seq) );

        my %ss3 = (
            'A' => 'up',
            'B' => 'down',
            'C' => 'right',
            'D' => 'left',
            'P' => 'f1',
            'Q' => 'f2',
            'R' => 'f3',
            'S' => 'f4',
        );
        my $key = $ss3{$final} // "ss3:$final";
        return { type => 'key', key => $key, rune => '', raw => $seq };
    }

    return undef;
}

1;

__END__
