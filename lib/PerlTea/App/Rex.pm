package PerlTea::App::Rex;

use strict;
use warnings;

use PerlTea ();
use PerlTea::Component::TextInput ();
use PerlTea::Width ();

=head1 NAME

PerlTea::App::Rex - a live regex playground

=head1 SYNOPSIS

    my $app = PerlTea::App::Rex->new( path => 'subject.txt' );
    PerlTea->new( model => $app, alt_screen => 1 )->run;

=head1 DESCRIPTION

C<PerlTea::App::Rex> is a PerlTea model that focuses a single-line pattern input
over a fixed subject text. As you type a Perl regular expression, every match is
highlighted in reverse video and the named captures of the first match are shown
in a status line. An invalid pattern is reported instead of crashing.

The match engine is exposed as three pure package functions
(L</compile_pattern>, L</find_matches>, L</highlight_line>) so they can be unit
tested without driving the event loop.

Keys: any printable character edits the pattern; C<Backspace> deletes; the arrow
keys move the cursor; C<q> (or C<Ctrl-C>) quits.

=cut

=head2 new

    my $app = PerlTea::App::Rex->new( path => $file );
    my $app = PerlTea::App::Rex->new( lines => \@lines, width => 80, height => 24 );

Construct the model. Provide the subject either as C<path> (a file that is read,
one line per row) or as C<lines> (an arrayref of strings). C<width>/C<height>
default to 80x24 and are corrected by the startup resize message.

=cut

sub new {
    my ( $class, %args ) = @_;

    my @lines;
    if ( defined $args{lines} ) {
        @lines = @{ $args{lines} };
    }
    elsif ( defined $args{path} ) {
        @lines = _read_lines( $args{path} );
    }
    @lines = ('') unless @lines;

    my $self = bless {
        lines   => \@lines,
        width   => $args{width}  || 80,
        height  => $args{height} || 24,
        re      => undef,
        error   => '',
        pattern => '',
    }, $class;

    $self->_rebuild_input;
    return $self;
}

=head2 init

Return the initial command (none).

=cut

sub init { return undef }

=head2 set_pattern

    $app->set_pattern('(?<id>ORD-\d+)');

Replace the current pattern with C<$str> and recompile it. Returns C<$self>.
Handy for tests and for non-interactive use.

=cut

sub set_pattern {
    my ( $self, $str ) = @_;
    $str = '' unless defined $str;
    $self->{input} = $self->_make_input($str);
    $self->_recompute;
    return $self;
}

=head2 update

    my ( $model, $cmd ) = $app->update($msg);

Fold a decoded key message. Resize messages re-size the input; C<q>/C<Ctrl-C>
quit; everything else is forwarded to the pattern input and the pattern is
recompiled live.

=cut

sub update {
    my ( $self, $msg ) = @_;
    my $type = $msg->{type} // '';

    if ( $type eq 'resize' ) {
        $self->{width}  = $msg->{width}  if $msg->{width};
        $self->{height} = $msg->{height} if $msg->{height};
        $self->_rebuild_input;
        return ( $self, undef );
    }

    my $key = $msg->{key} // '';
    return ( PerlTea->quit, undef ) if $key eq 'q' || $key eq 'ctrl+c';

    $self->{input}->handle_msg($msg);
    $self->_recompute;
    return ( $self, undef );
}

=head2 view

Render a title header, the pattern prompt, a status line (match count, or the
error), a separator, the subject with matches highlighted, a "Matches (N):"
panel listing every match with its position and named captures, and a key-hint
footer. The match panel sits directly under the subject so there is no dead gap.

=cut

sub view {
    my ($self) = @_;
    my $w = $self->{width};
    my $h = $self->{height};
    $w = 1 if $w < 1;
    $h = 6 if $h < 6;

    my $title  = "\e[1mptea-rex\e[22m \e[2m- regex playground\e[22m";
    my $prompt = "\e[1mPattern:\e[22m " . $self->{input}->view;

    my $status = $self->{error} ne ''
        ? "\e[1m\e[31mError:\e[39m\e[22m " . $self->{error}
        : $self->_match_summary;

    my @out;
    push @out, _fit( $title,  $w );
    push @out, $prompt;
    push @out, _fit( $status, $w );
    push @out, ( '-' x $w );

    my $footer_row = $h - 1;
    # Header(1) + prompt(1) + status(1) + rule(1) already pushed.
    my $body_rows  = $footer_row - @out;
    $body_rows = 0 if $body_rows < 0;

    push @out, $self->_body_lines( $body_rows, $w );
    push @out, '' while @out < $footer_row;
    push @out, _fit( 'q: quit   type: edit pattern   backspace: delete   arrows: move cursor', $w );

    return join( "\n", @out );
}

# Trim/pad a single styled line to exactly $width visible columns (ANSI-aware).
sub _fit {
    my ( $line, $width ) = @_;
    $line = '' unless defined $line;
    $line =~ s/\n/ /g;
    my $len = PerlTea::Width::display_width($line);
    return PerlTea::Width::truncate_to_width( $line, $width ) if $len > $width;
    return $line . ( ' ' x ( $width - $len ) );
}

# ── pure match engine (unit tested directly) ────────────────────────────────

=head2 compile_pattern

    my ( $re, $err ) = PerlTea::App::Rex::compile_pattern($str);

Compile C<$str> into a regex. On success returns C<($qr, undef)>; on a syntax
error returns C<(undef, $message)> with the trailing C<"at ... line N"> stripped.
An empty/undefined pattern returns C<(undef, undef)>.

=cut

sub compile_pattern {
    my ($str) = @_;
    return ( undef, undef ) unless defined $str && length $str;
    my $re = eval { qr/$str/ };
    if ($@) {
        my $err = $@;
        $err =~ s/ at .* line \d+.*//s;
        $err =~ s/\s+\z//;
        return ( undef, $err );
    }
    return ( $re, undef );
}

=head2 find_matches

    my @spans = PerlTea::App::Rex::find_matches($re, $text);

Return the list of non-overlapping matches of C<$re> in C<$text>, each as a hash
ref C<{ start, end, text, captures }> where C<start>/C<end> are character offsets
(C<end> is exclusive) and C<captures> is a hashref of named captures for that
match. Patterns that can match the empty string yield no spans (so the caller
cannot loop forever on a zero-width match).

=cut

sub find_matches {
    my ( $re, $text ) = @_;
    return () unless defined $re && defined $text;
    return () if '' =~ /$re/;    # zero-width pattern: skip (avoids infinite loop)

    my @spans;
    while ( $text =~ /$re/g ) {
        my ( $s, $e ) = ( $-[0], $+[0] );
        my %caps = %+;           # named captures of this match
        push @spans, {
            start    => $s,
            end      => $e,
            text     => substr( $text, $s, $e - $s ),
            captures => { %caps },
        };
        pos($text) = $e + 1 if $e == $s;    # belt-and-braces zero-width guard
    }
    return @spans;
}

=head2 highlight_line

    my $styled = PerlTea::App::Rex::highlight_line($re, $text);

Return C<$text> with every match of C<$re> wrapped in reverse-video SGR
(C<\e[7m> ... C<\e[27m>). Options C<on>/C<off> override the wrapping sequences.
With no regex (or a zero-width pattern) the text is returned unchanged.

=cut

sub highlight_line {
    my ( $re, $text, %opt ) = @_;
    return $text unless defined $re && defined $text;
    return $text if '' =~ /$re/;    # zero-width pattern: nothing to wrap
    my $on  = defined $opt{on}  ? $opt{on}  : "\e[7m";
    my $off = defined $opt{off} ? $opt{off} : "\e[27m";
    ( my $out = $text ) =~ s/$re/$on$&$off/g;
    return $out;
}

# ── internals ───────────────────────────────────────────────────────────────

sub _read_lines {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot open $path: $!\n";
    my @lines;
    while ( my $line = <$fh> ) {
        chomp $line;
        push @lines, $line;
    }
    close $fh;
    return @lines;
}

sub _make_input {
    my ( $self, $value ) = @_;
    my $iw = $self->{width} - 9;    # leave room for the "Pattern: " label
    $iw = 1 if $iw < 1;
    return PerlTea::Component::TextInput->new(
        width       => $iw,
        value       => $value,
        focus       => 1,
        placeholder => 'type a regex',
    );
}

sub _rebuild_input {
    my ($self) = @_;
    my $val = defined $self->{input} ? $self->{input}->value : '';
    $self->{input} = $self->_make_input($val);
    return;
}

sub _recompute {
    my ($self) = @_;
    my $str = $self->{input}->value;
    $self->{pattern} = $str;
    my ( $re, $err ) = compile_pattern($str);
    $self->{re}    = $re;
    $self->{error} = defined $err ? $err : '';
    return;
}

# Body: the subject text (matches highlighted) followed immediately by a
# "Matches (N):" panel that lists every match with its line/column position and
# any named captures. Everything is fit to $w columns so alignment stays clean.
sub _body_lines {
    my ( $self, $rows, $w ) = @_;
    $w = $self->{width} unless defined $w;
    $w = 1 if $w < 1;
    my $re = $self->{re};

    my @out;

    # ── Subject panel ────────────────────────────────────────────────────────
    push @out, _fit( "\e[1mSubject:\e[22m", $w );
    for my $line ( @{ $self->{lines} } ) {
        last if @out >= $rows;
        push @out, _fit( defined $re ? highlight_line( $re, $line ) : $line, $w );
    }

    # ── Matches panel (right under the subject — no dead gap) ─────────────────
    my @matches = $self->_all_matches;
    my $n = scalar @matches;
    push @out, _fit( '', $w ) if @out < $rows;             # one blank spacer row
    push @out, _fit( "\e[1mMatches (\e[36m$n\e[39m):\e[22m", $w )
        if @out < $rows;

    if ( !defined $re ) {
        push @out, _fit( "\e[2mtype a pattern above to search\e[22m", $w )
            if @out < $rows;
    }
    elsif ( $n == 0 ) {
        push @out, _fit( "\e[2m(no matches)\e[22m", $w ) if @out < $rows;
    }
    else {
        my $idx = 0;
        for my $m (@matches) {
            last if @out >= $rows;
            $idx++;
            push @out, _fit( $self->_match_line( $idx, $m ), $w );
        }
    }

    return @out;
}

# One formatted line for a single match in the Matches panel:
#   "1. ORD-0001  @ line 3, col 12   id=ORD-0001"
sub _match_line {
    my ( $self, $idx, $m ) = @_;
    my $num  = sprintf '%2d.', $idx;
    my $text = "\e[7m" . $m->{text} . "\e[27m";
    my $pos  = "\e[2m\@ line $m->{line}, col " . ( $m->{start} + 1 ) . "\e[22m";

    my $caps = $m->{captures};
    my $cap_str = '';
    if ( $caps && %$caps ) {
        $cap_str = '   '
            . "\e[36m"
            . join( ', ', map { "$_=$caps->{$_}" } sort keys %$caps )
            . "\e[39m";
    }
    return "$num $text  $pos$cap_str";
}

# Collect every match across every subject line, tagged with a 1-based line no.
sub _all_matches {
    my ($self) = @_;
    my $re = $self->{re};
    return () unless defined $re;
    my @all;
    my $ln = 0;
    for my $line ( @{ $self->{lines} } ) {
        $ln++;
        for my $m ( find_matches( $re, $line ) ) {
            $m->{line} = $ln;
            push @all, $m;
        }
    }
    return @all;
}

sub _match_summary {
    my ($self) = @_;
    my $re = $self->{re};
    return "\e[2mtype a pattern to search\e[22m" unless defined $re;

    my @matches = $self->_all_matches;
    my $count   = scalar @matches;

    my %names;
    for my $m (@matches) {
        $names{$_} = 1 for keys %{ $m->{captures} };
    }

    my $summary = $count == 1 ? '1 match' : "$count matches";
    if (%names) {
        $summary .= '   '
            . "\e[2mcaptures: "
            . join( ', ', sort keys %names )
            . "\e[22m";
    }
    return $summary;
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
