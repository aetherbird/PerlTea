package PerlTea::App::Logexplorer;

use strict;
use warnings;

use PerlTea;
use PerlTea::Component::TextInput;
use PerlTea::Component::Viewport;

=head1 NAME

PerlTea::App::Logexplorer - read and display a log source in a scrollable viewport

=head1 SYNOPSIS

    use PerlTea;
    use PerlTea::App::Logexplorer;

    my $app = PerlTea::App::Logexplorer->new( path => '/var/log/syslog' );
    PerlTea->new( model => $app, alt_screen => 1 )->run;

=head1 DESCRIPTION

C<PerlTea::App::Logexplorer> is the shared module behind the B-series log
explorer demos (C<cmd/b1.pl> .. C<cmd/b4.pl>). It is a PerlTea model: it loads
lines from a log source, holds them in a L<PerlTea::Component::Viewport> for
scrolling, optionally live-tails file sources, filters the view with a regex,
and quits on C<q>.

A source is chosen explicitly with the C<path> / C<command> options, or picked
automatically with L</default_source> when neither is given. The default prefers
a readable system log (C<journalctl>, C</var/log/syslog>, the macOS C<log>
command), and falls back to a bundled fixture so the explorer always has
something to show.

=cut

# Bundled fixture used as the last-resort default source. Resolved relative to
# this module so it works regardless of the caller's working directory.
sub _fixture_path {
    ( my $base = __FILE__ ) =~ s{lib/PerlTea/App/Logexplorer\.pm$}{};
    $base = '.' if $base eq '';
    return $base . 'testdata/log/sample.log';
}

=head2 default_source

    my $src = PerlTea::App::Logexplorer::default_source(%opts);

Return a source descriptor (a hashref) for the best available default log. A
file descriptor is C<< { type => 'file', path => $path } >>; a command
descriptor is C<< { type => 'command', command => [ @argv ] } >>.

Detection order: a readable system log file (C</var/log/syslog>,
C</var/log/messages>, C</var/log/system.log>), then C<journalctl> if present,
then the macOS C<log> command, then the bundled fixture. Pass C<candidates>
(an arrayref of file paths) and/or C<fixture> to override for testing.

=cut

sub default_source {
    my (%opts) = @_;

    my $candidates = $opts{candidates}
        || [ '/var/log/syslog', '/var/log/messages', '/var/log/system.log' ];
    for my $path (@$candidates) {
        return { type => 'file', path => $path } if -r $path;
    }

    if ( !$opts{candidates} ) {    # only probe real commands for the real default
        if ( _have_command('journalctl') ) {
            return { type => 'command',
                command => [qw(journalctl --no-pager -n 1000)] };
        }
        if ( _have_command('log') ) {    # macOS unified logging
            return { type => 'command',
                command => [qw(log show --last 1h)] };
        }
    }

    my $fixture = defined $opts{fixture} ? $opts{fixture} : _fixture_path();
    return { type => 'file', path => $fixture };
}

# True if $name is an executable on PATH. Pure-core, no External deps.
sub _have_command {
    my ($name) = @_;
    return 0 if $name =~ m{/};
    for my $dir ( split /:/, ( $ENV{PATH} // '' ) ) {
        next unless length $dir;
        return 1 if -x "$dir/$name";
    }
    return 0;
}

=head2 new

    my $app = PerlTea::App::Logexplorer->new(
        path => $file, width => 80, height => 24, live_tail => 1,
    );

Construct the model. Options: C<path> (a file to read), C<command> (an arrayref
to run and capture), C<width>, C<height>, C<live_tail>, and
C<tail_interval>. With neither C<path> nor C<command>, the source comes from
L</default_source>. The source is loaded immediately.

=cut

sub new {
    my ( $class, %args ) = @_;

    my $source;
    if ( defined $args{command} ) {
        $source = { type => 'command', command => $args{command} };
    }
    elsif ( defined $args{path} ) {
        $source = { type => 'file', path => $args{path} };
    }
    else {
        $source = default_source();
    }

    my $width  = $args{width}  || 80;
    my $height = $args{height} || 24;

    my $self = bless {
        source => $source,
        width  => $width,
        height => $height,
        all_lines      => [],
        filtered_lines => [],
        live_tail     => $args{live_tail} ? 1 : 0,
        tail_interval => $args{tail_interval} || 0.25,
        tail_pos      => 0,
        tail_partial  => '',
        filter_mode        => 0,
        filter_pattern     => undef,
        filter_pattern_src => '',
        filter_error       => '',
        filter_input   => PerlTea::Component::TextInput->new(
            width       => $width > 1 ? $width - 1 : 1,
            placeholder => 'pattern',
        ),
    }, $class;

    $self->load;
    $self->_sync_tail_position;
    return $self;
}

=head2 load

Read all lines from the configured source into the model and (re)build the
viewport. Returns the model. A source that cannot be read yields a single
diagnostic line rather than dying, so the explorer stays usable.

=cut

sub load {
    my ($self) = @_;
    $self->{all_lines} = $self->_read_source( $self->{source} );
    if ( !$self->{viewport} ) {
        $self->{viewport} = PerlTea::Component::Viewport->new(
            width   => $self->{width},
            height  => $self->_frame_height,
            content => '',
        );
    }
    $self->_apply_filter;
    return $self;
}

# Read a source descriptor into an arrayref of chomped lines.
sub _read_source {
    my ( $self, $source ) = @_;
    my @lines;

    if ( $source->{type} eq 'command' ) {
        my @cmd = @{ $source->{command} };
        if ( open my $fh, '-|', @cmd ) {
            while ( my $line = <$fh> ) {
                chomp $line;
                push @lines, $line;
            }
            close $fh;
        }
        else {
            push @lines, "[logexplorer] cannot run @cmd: $!";
        }
    }
    else {    # file
        my $path = $source->{path};
        if ( open my $fh, '<', $path ) {
            while ( my $line = <$fh> ) {
                chomp $line;
                push @lines, $line;
            }
            close $fh;
        }
        else {
            push @lines, "[logexplorer] cannot open $path: $!";
        }
    }

    @lines = ('') unless @lines;
    return \@lines;
}

=head2 lines

Return the loaded (unfiltered) log lines as a list (or arrayref in scalar
context).

=cut

sub lines {
    my ($self) = @_;
    return wantarray ? @{ $self->{all_lines} } : $self->{all_lines};
}

=head2 filtered_lines

Return the currently displayed log lines — the filtered subset when a filter
is active, otherwise the full set.

=cut

sub filtered_lines {
    my ($self) = @_;
    return wantarray ? @{ $self->{filtered_lines} } : $self->{filtered_lines};
}

=head2 subscriptions

PerlTea model hook. When C<live_tail> is enabled for a file source, returns a
timer subscription that asks the model to poll for appended lines.

=cut

sub subscriptions {
    my ($self) = @_;
    return [] unless $self->{live_tail};
    return [] unless $self->{source}{type} eq 'file';
    return [
        {
            every => $self->{tail_interval},
            msg   => sub { return { type => 'tail_tick' } },
        }
    ];
}

=head2 viewport

Return the underlying L<PerlTea::Component::Viewport>.

=cut

sub viewport { return $_[0]->{viewport} }

=head2 init

PerlTea model hook. No startup command for B1.

=cut

sub init { return undef }

=head2 update

PerlTea model hook. Handles C<resize> (reflow the viewport), navigation keys
(C<up>/C<k>, C<down>/C<j>, C<pgup>/C<pgdown>, C<home>/C<g>, C<end>/C<G>),
filter mode (C</> to open, C<Enter> to apply, C<Esc> to cancel), and C<q> to
quit.

=cut

sub update {
    my ( $self, $msg ) = @_;

    # Any keypress clears a transient invalid-regex message.
    if ( $self->{filter_error} && ( $msg->{type} // '' ) eq 'key' ) {
        $self->{filter_error} = '';
        $self->_resize_body;
    }

    if ( ( $msg->{type} // '' ) eq 'resize' ) {
        $self->{width}  = $msg->{width}  if $msg->{width};
        $self->{height} = $msg->{height} if $msg->{height};
        $self->{filter_input}{width}
            = $self->{width} > 1 ? $self->{width} - 1 : 1;
        $self->_resize_body;
        return ( $self, undef );
    }

    if ( ( $msg->{type} // '' ) eq 'tail_tick' ) {
        $self->_poll_tail;
        return ( $self, undef );
    }

    my $key = $msg->{key} // '';

    if ( $self->{filter_mode} ) {
        if ( $key eq 'enter' ) {
            $self->_apply_filter_input;
        }
        elsif ( $key eq 'esc' ) {
            $self->_cancel_filter;
        }
        else {
            $self->{filter_input}->handle_msg($msg);
        }
        return ( $self, undef );
    }

    return ( PerlTea->quit, undef ) if $key eq 'q';

    if ( $key eq '/' ) {
        $self->_enter_filter_mode;
        return ( $self, undef );
    }

    if ( $key eq 'esc' && defined $self->{filter_pattern} ) {
        $self->_cancel_filter;
        return ( $self, undef );
    }

    my $vp = $self->{viewport};
    if    ( $key eq 'up'   || $key eq 'k' ) { $vp->scroll_up }
    elsif ( $key eq 'down' || $key eq 'j' ) { $vp->scroll_down }
    elsif ( $key eq 'pgup' )                { $vp->page_up }
    elsif ( $key eq 'pgdown' )              { $vp->page_down }
    elsif ( $key eq 'home' || $key eq 'g' ) { $vp->goto_top }
    elsif ( $key eq 'end'  || $key eq 'G' ) { $vp->goto_bottom }

    return ( $self, undef );
}

=head2 view

PerlTea model hook. Render full chrome around the log: a header bar (source
name, line counts, an active-filter note, and a LIVE tail indicator), the
scrollable log body, an optional filter-prompt / error row, and a key-hint
footer. When the filter prompt is open the prompt row reads C</[pattern]>; when
a regex is rejected the same row carries the error message.

=cut

sub view {
    my ($self) = @_;
    my $w = $self->{width} > 0 ? $self->{width} : 80;

    my @out;
    push @out, $self->_header_line($w);
    push @out, $self->_body_rows;

    if ( $self->{filter_mode} ) {
        push @out, '/' . $self->{filter_input}->view;
    }
    elsif ( length $self->{filter_error} ) {
        push @out, _color( '91', _fit_line( $self->{filter_error}, $w ) );
    }

    push @out, $self->_footer_line($w);
    return join "\n", @out;
}

# The top chrome row: source name + shown/total counts + filter note + a LIVE
# tail badge, dim-styled so the log body stays the focus.
sub _header_line {
    my ( $self, $w ) = @_;

    my $name  = $self->_source_label;
    my $total = scalar @{ $self->{all_lines} };
    my $shown = scalar @{ $self->{filtered_lines} };

    my $count = defined $self->{filter_pattern}
        ? "$shown/$total lines"
        : "$total lines";

    my $left = " $name  $count";
    if ( defined $self->{filter_pattern} ) {
        $left .= "  filter:/" . $self->{filter_pattern_src} . "/";
    }

    my $badge = $self->{live_tail} ? 'LIVE' : 'FILE';
    my $right = "[$badge] ";

    my $gap = $w - length($left) - length($right);
    my $bar;
    if ( $gap >= 0 ) {
        $bar = $left . ( ' ' x $gap ) . $right;
    }
    else {
        $bar = _fit_line( $left, $w );    # too narrow: drop the badge
    }

    # Dim the whole bar, but make the LIVE badge stand out in bright green.
    if ( $self->{live_tail} && $gap >= 0 ) {
        return _color( '2', $left . ( ' ' x $gap ) )
            . _color( '1;92', $right );
    }
    return _color( '2', $bar );
}

# A short, friendly label for the active source.
sub _source_label {
    my ($self) = @_;
    my $src = $self->{source};
    if ( $src->{type} eq 'command' ) {
        return join ' ', @{ $src->{command} };
    }
    ( my $base = $src->{path} ) =~ s{.*/}{};
    return length $base ? $base : $src->{path};
}

# The bottom chrome row: a dim key-hint footer.
sub _footer_line {
    my ( $self, $w ) = @_;
    my $hint = $self->{filter_mode}
        ? 'Enter: apply   Esc: cancel   q: quit'
        : '/: filter   up/down j/k: scroll   g/G: ends   q: quit';
    return _color( '2', _fit_line( $hint, $w ) );
}

# Wrap $text in an SGR sequence ($code, e.g. '2' or '1;92') and a reset. Kept
# tiny and dependency-free; matches the raw-escape style used across the apps.
sub _color {
    my ( $code, $text ) = @_;
    return "\e[${code}m" . $text . "\e[0m";
}

# Set the starting read offset for live tailing to the source's current EOF.
sub _sync_tail_position {
    my ($self) = @_;
    return unless $self->{source}{type} eq 'file';
    my $path = $self->{source}{path};
    my $size = -s $path;
    $self->{tail_pos} = defined $size ? $size : 0;
    $self->{tail_partial} = '';
    return;
}

# Poll a file source for bytes appended since the last read and append complete
# lines to the viewport. Partial trailing lines are retained until newline.
sub _poll_tail {
    my ($self) = @_;
    return unless $self->{live_tail};
    return unless $self->{source}{type} eq 'file';

    my $path = $self->{source}{path};
    my $size = -s $path;
    return unless defined $size;

    $self->{tail_pos} = 0 if $size < $self->{tail_pos};    # truncation/rotation
    return if $size == $self->{tail_pos};

    return unless open my $fh, '<', $path;
    seek $fh, $self->{tail_pos}, 0;
    my $bytes = '';
    {
        local $/;
        $bytes = <$fh>;
    }
    $self->{tail_pos} = tell($fh);
    close $fh;
    return unless defined $bytes && length $bytes;

    $bytes = $self->{tail_partial} . $bytes;
    my @parts = split /\n/, $bytes, -1;
    $self->{tail_partial} = pop @parts;
    return unless @parts;

    my $at_bottom = $self->{viewport}->offset >= $self->_max_view_offset;
    push @{ $self->{all_lines} }, @parts;
    $self->_apply_filter;
    $self->{viewport}->goto_bottom if $at_bottom;
    return;
}

sub _max_view_offset {
    my ($self) = @_;
    my $max = @{ $self->{filtered_lines} } - $self->{viewport}{height};
    return $max > 0 ? $max : 0;
}

# The viewport spans the full frame height. Sizing it to the full height (not the
# smaller body area) keeps its reported scroll offset on the full-window
# coordinate system: goto_bottom lands on lines - height, the "last full window"
# the scale tests assert. Always at least 1 so it stays usable on tiny terminals.
sub _frame_height {
    my ($self) = @_;
    my $h = $self->{height};
    return $h > 1 ? $h : 1;
}

# Rows available to the log body = total height minus the header and footer
# chrome (always present) minus one more for the prompt/error row when shown.
# Always at least 1 so the body stays visible on tiny terminals.
sub _body_height {
    my ($self) = @_;
    my $chrome = 2;    # header + footer
    $chrome += 1 if $self->{filter_mode} || length $self->{filter_error};
    my $h = $self->{height} - $chrome;
    return $h > 1 ? $h : 1;
}

# Render the log body: exactly _body_height rows drawn from the full-height
# viewport window. The viewport is `height` tall so its scroll offset is reported
# on the full-window coordinate system; the chrome (header/footer/prompt) is laid
# out around the body without shrinking the viewport. Because the body is shorter
# than the viewport window by the chrome size, the body slides within that window:
# top-anchored while scrolling through the middle, then bottom-anchored at the end
# so the very last line is visible exactly when the offset is clamped at the
# bottom (lines - height).
sub _body_rows {
    my ($self) = @_;
    my @window = split /\n/, $self->{viewport}->view, -1;
    my $body_h = $self->_body_height;
    my $slack  = @window - $body_h;             # chrome rows the body gives up
    $slack = 0 if $slack < 0;

    # The body is top-anchored within the viewport window everywhere except the
    # final stretch of a log that actually overflows: there the body bottom-anchors
    # so the very last line is visible exactly when the offset is clamped at the
    # bottom (lines - height). When the log fits (max offset 0) there is nothing
    # below to reach, so the body stays at the top.
    my $offset = $self->{viewport}->offset;
    my $max    = $self->{viewport}->can('_max_offset')
        ? $self->{viewport}->_max_offset
        : ( @{ $self->{filtered_lines} } - @window );
    $max = 0 if $max < 0;
    my $start = 0;
    if ( $max > 0 && $max - $offset <= $slack ) {
        $start = $slack - ( $max - $offset );
    }
    $start = 0      if $start < 0;
    $start = $slack if $start > $slack;

    return @window[ $start .. $start + $body_h - 1 ];
}

# Resize the viewport to the current frame height (call after anything that
# changes height, filter mode, or the error state). The viewport stays full
# height; only the body slice within view() reacts to chrome changes.
sub _resize_body {
    my ($self) = @_;
    $self->{viewport}->resize(
        width  => $self->{width},
        height => $self->_frame_height,
    );
    return;
}

# Enter filter-edit mode: make room for the prompt row and focus the text input.
sub _enter_filter_mode {
    my ($self) = @_;
    $self->{filter_mode} = 1;
    $self->{filter_error} = '';
    $self->{filter_input}->set_focus(1);
    $self->_resize_body;
    return;
}

# Apply the current input value as a regex filter. On success the viewport is
# restored to full height; on error the error is surfaced and the viewport stays
# shrunk so the message is visible.
sub _apply_filter_input {
    my ($self) = @_;
    my $value = $self->{filter_input}->value;
    my ( $ok, $err ) = $self->_set_filter($value);

    $self->{filter_mode} = 0;
    $self->{filter_input}->set_focus(0);
    $self->{filter_input} = PerlTea::Component::TextInput->new(
        width       => $self->{width} > 1 ? $self->{width} - 1 : 1,
        placeholder => 'pattern',
    );

    if ($ok) {
        $self->{filter_error} = '';
        $self->_resize_body;
    }
    else {
        $self->{filter_error} = "invalid regex: $err";
        $self->{filter_pattern}     = undef;
        $self->{filter_pattern_src} = '';
        $self->_apply_filter;    # restore unfiltered view
        $self->_resize_body;     # keep room for the error row
    }
    return;
}

# Cancel filtering without applying, restoring the unfiltered view.
sub _cancel_filter {
    my ($self) = @_;
    $self->{filter_mode} = 0;
    $self->{filter_error} = '';
    $self->{filter_input}->set_focus(0);
    $self->{filter_input} = PerlTea::Component::TextInput->new(
        width       => $self->{width} > 1 ? $self->{width} - 1 : 1,
        placeholder => 'pattern',
    );
    $self->{filter_pattern}     = undef;
    $self->{filter_pattern_src} = '';
    $self->_apply_filter;
    $self->_resize_body;
    return;
}

# Compile $pattern_str as a regex; on success store it and rebuild the view.
sub _set_filter {
    my ( $self, $pattern_str ) = @_;
    if ( !defined $pattern_str || $pattern_str eq '' ) {
        $self->{filter_pattern}     = undef;
        $self->{filter_pattern_src} = '';
        $self->_apply_filter;
        return ( 1, undef );
    }
    my $re = eval { qr/$pattern_str/ };
    if ($@) {
        my $err = $@;
        $err =~ s/ at .* line \d+.*//s;
        return ( 0, $err );
    }
    $self->{filter_pattern}     = $re;
    $self->{filter_pattern_src} = $pattern_str;
    $self->_apply_filter;
    return ( 1, undef );
}

# Rebuild filtered_lines and the viewport from all_lines + the active pattern.
sub _apply_filter {
    my ($self) = @_;
    my $pattern = $self->{filter_pattern};
    my @filtered = defined $pattern
        ? grep { /$pattern/ } @{ $self->{all_lines} }
        : @{ $self->{all_lines} };
    @filtered = ('') unless @filtered;

    $self->{filtered_lines} = \@filtered;
    my @display = map { $self->_decorate_line($_) } @filtered;
    $self->{viewport}->set_content( \@display );
    return;
}

# Style one display line. With a filter active, matches are wrapped in reverse
# video (and nothing else, so the highlight reads cleanly). With no filter, the
# leading timestamp is dimmed and level words are colorized for scannability.
sub _decorate_line {
    my ( $self, $line ) = @_;
    return $self->_highlight_line($line) if defined $self->{filter_pattern};
    return $self->_colorize_line($line);
}

# Wrap regex matches in reverse video so they stand out in the log view.
sub _highlight_line {
    my ( $self, $line ) = @_;
    my $pattern = $self->{filter_pattern} or return $line;
    return $line if '' =~ /$pattern/;    # avoid infinite loop on zero-width match
    my $start = "\e[7m";
    my $end   = "\e[27m";
    $line =~ s/$pattern/$start$&$end/g;
    return $line;
}

# Cosmetic styling for the unfiltered view: dim a leading syslog timestamp
# (e.g. "Jun 13 10:00:01") and color severity words so WARN/ERROR pop. Only the
# timestamp prefix and standalone level words are touched, so the raw text stays
# intact and readable.
my %LEVEL_SGR = (
    ERROR    => '91',    # bright red
    ERR      => '91',
    CRITICAL => '91',
    CRIT     => '91',
    FATAL    => '91',
    WARN     => '93',    # bright yellow
    WARNING  => '93',
    INFO     => '96',    # bright cyan
    DEBUG    => '90',    # bright black / grey
    TRACE    => '90',
    NOTICE   => '96',
);

sub _colorize_line {
    my ( $self, $line ) = @_;

    # Dim a leading "Mon DD HH:MM:SS" syslog timestamp if present.
    $line =~ s/^([A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})/"\e[2m$1\e[22m"/e;

    # Color standalone level words (word-boundary, all-caps tokens we know).
    my $alt = join '|', map { quotemeta } keys %LEVEL_SGR;
    $line =~ s/\b($alt)\b/"\e[" . $LEVEL_SGR{$1} . "m$1\e[39m"/ge;

    return $line;
}

# Pad/truncate a plain prompt/error line to the model width.
sub _fit_line {
    my ( $line, $width ) = @_;
    $line = substr( $line, 0, $width ) if length($line) > $width;
    return $line . ( ' ' x ( $width - length($line) ) );
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
