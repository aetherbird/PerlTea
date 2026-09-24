package PerlTea;

use strict;
use warnings;
use Carp qw(croak);
use POSIX qw(:termios_h);
use IO::Select;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Time::HiRes ();
use Storable ();
use Encode qw(encode is_utf8);
use PerlTea::Renderer;
use PerlTea::Input;

our $VERSION = '0.02';

# PerlTea is an MVU (model / update / view) terminal-UI framework — a from-scratch,
# zero-dependency Perl take on the Bubble Tea architecture. Your program is a
# *model*: an object that knows how to fold a message into its next state (update)
# and render itself to a string (view). The framework owns the event loop, raw-mode
# terminal setup, input decoding, the diffing renderer, and teardown.
#
# This module is the public core. The event loop, raw-mode terminal setup, input
# decoding, the diffing renderer, and the command/subscription machinery (gates
# G0–G3) are implemented below; styling, layout, and components live in their own
# PerlTea::* modules.

=head1 NAME

PerlTea - an MVU (model/update/view) terminal UI framework in pure core Perl

=head1 SYNOPSIS

    use PerlTea;

    package Counter;
    sub new    { bless { count => 0 }, shift }
    sub init   { return undef }                       # optional initial command
    sub update {
        my ($self, $msg) = @_;
        return (PerlTea->quit, undef) if $msg->{key} && $msg->{key} eq 'q';
        $self->{count}++ if $msg->{key} && $msg->{key} eq 'up';
        return ($self, undef);                        # (next_model, command)
    }
    sub view   { my ($self) = @_; "Counter: $self->{count}\n" }

    package main;
    PerlTea->new( model => Counter->new, alt_screen => 1 )->run;

=head1 MODEL CONTRACT

A model is any object providing:

=over 4

=item * C<< ($model, $cmd) = $model->update($msg) >> — fold a message into the next
model and an optional command (a coderef run asynchronously whose returned message
re-enters update). Returning C<< (PerlTea->quit, ...) >> ends the program.

=item * C<< $string = $model->view() >> — render the current state. The renderer
diffs this against the previous frame and emits the minimal byte delta (gate G1).

=item * C<< $cmd = $model->init() >> — optional; an initial command run at startup.

=item * C<< $subs = $model->subscriptions() >> — optional; an arrayref of
subscription descriptors. Each is C<< { every => $seconds, msg => sub { ... } } >>:
every C<$seconds> the C<msg> coderef is called and its return value is folded into
C<update>. Subscriptions feed timers/streams without blocking the loop (gate G3).

=back

=head1 COMMANDS

A B<command> is a coderef returned as the second value from C<update> (or from
C<init>). The framework runs it B<asynchronously> in a forked child so the event
loop never blocks; the value the coderef returns is sent back into C<update> as a
message when it completes. Command return values must be plain data (hashes,
arrays, scalars) — they are serialized across a pipe with core C<Storable>.

=head1 METHODS

=cut

=head2 new

    my $p = PerlTea->new( model => $model, alt_screen => 1 );

Construct a program for the given model. Options: C<alt_screen> (use the alternate
screen buffer), C<out>/C<in> (filehandles; default STDOUT/STDIN).

=cut

sub new {
    my ($class, %args) = @_;
    croak "PerlTea->new requires a 'model'" unless defined $args{model};
    my $self = {
        model      => $args{model},
        alt_screen => $args{alt_screen} ? 1 : 0,
        out        => $args{out} || \*STDOUT,
        in         => $args{in}  || \*STDIN,
    };
    return bless $self, $class;
}

=head2 model

The model the program was constructed with (updated as the loop runs).

=cut

sub model { return $_[0]->{model} }

=head2 quit

Return the canonical quit message; returning it from C<update> ends the loop.

=cut

sub quit { return PerlTea::Msg::Quit->new }

=head2 run

    my $final_model = $p->run;

Start the event loop and block until the program quits, returning the final model.

The loop: render the model's C<view>, block for input, decode each keypress into a
message, fold it through C<update>, and repeat. Returning C<< PerlTea->quit >> as the
next model ends the loop. End-of-input on the controlling terminal also ends it.

The terminal is ALWAYS restored on the way out — raw mode off, cursor shown, and the
alternate screen exited if it was entered — whether the program quits normally, is
interrupted with Ctrl-C (SIGINT/SIGTERM), or dies from an uncaught exception. On an
uncaught die the exception is re-thrown after the terminal is restored, so the
process exits non-zero (gate G0).

=cut

sub run {
    my ($self) = @_;

    $self->_enter_raw;

    # One-shot, idempotent teardown shared by every exit path.
    $self->{_torn_down} = 0;
    my $restore = sub { $self->_leave_raw };

    # External Ctrl-C / kill: restore the terminal, then exit. We cannot return
    # through the loop here because the signal interrupts a blocking read.
    local $SIG{INT}  = sub { $restore->(); CORE::exit(130) };
    local $SIG{TERM} = sub { $restore->(); CORE::exit(143) };
    local $SIG{WINCH} = sub { $self->{_resized} = 1 };

    my $final;
    my $ok = eval {
        $final = $self->_loop;
        1;
    };
    my $err = $@;

    # Restore on EVERY path: normal return AND uncaught die.
    $restore->();
    $self->_reap_all_cmds;    # don't leave async command children behind

    die $err if !$ok;    # re-throw so an uncaught panic exits non-zero
    return $final;
}

# The MVU event loop. Renders, reads a key, folds it through update, repeats.
# The loop is non-blocking — it waits on input AND any in-flight command pipes
# with a timeout computed from the next due subscription, so the keyboard stays
# responsive while a clock ticks and a background task runs.
sub _loop {
    my ($self) = @_;
    my $model = $self->{model};

    $self->{_cmds}        = {};
    $self->{_inline_msgs} = [];

    # An optional initial command runs at startup, asynchronously.
    if ( $model->can('init') ) {
        my $cmd = $model->init;
        $self->_dispatch_cmd($cmd) if $cmd;
    }

    $self->_init_subs($model);

    $self->_ensure_renderer;

    my $infd = fileno( $self->{in} );
    my $real_in = defined $infd && $infd >= 0;

    # Deliver the initial terminal size before the first frame so a layout-aware
    # model can size itself at startup — no SIGWINCH fires when the program opens,
    # so without this a resizable UI would render at a default size until the user
    # happened to resize. Only on a real fd, where _terminal_size is meaningful;
    # in-memory test handles take the buffered path with a fixed default size.
    if ( $real_in && $model->can('update') ) {
        my ( $cols, $rows ) = $self->_terminal_size;
        my ($next) = $model->update(
            { type => 'resize', width => $cols, height => $rows } );
        if ( defined $next
            && !( ref $next && $next->isa('PerlTea::Msg::Quit') ) )
        {
            $self->{model} = $model = $next;
        }
    }

    $self->_render( $model->view );

    # In-memory handles (tests/pipes that can't sysread) use the simple buffered
    # path; a real fd uses the non-blocking select loop with subscriptions.
    return $self->_loop_buffered($model) unless $real_in;

    my $input_open = 1;

    while (1) {
        if ( delete $self->{_resized} ) {
            $model = $self->_handle_resize($model);
        }

        my $sel = IO::Select->new;
        $sel->add( $self->{in} ) if $input_open;
        $sel->add( $_->{fh} ) for values %{ $self->{_cmds} };

        # Nothing left to wait on and no subscriptions: end cleanly.
        last if $sel->count == 0 && !@{ $self->{_subs} };

        my @ready = $sel->can_read( $self->_next_timeout );

        my @msgs = @{ delete $self->{_inline_msgs} };
        $self->{_inline_msgs} = [];

        for my $fh (@ready) {
            if ( $input_open && fileno($fh) == $infd ) {
                my $bytes = $self->_read_bytes;
                if ( !defined $bytes ) { $input_open = 0; next; }
                next if $bytes eq '';    # resize-interrupted; redraw next pass
                push @msgs, $self->_decode($bytes);
            }
            else {
                push @msgs, $self->_collect_cmd($fh);
            }
        }

        push @msgs, $self->_due_sub_msgs;

        if (@msgs) {
            my ( $next, $quit ) = $self->_apply( $model, @msgs );
            $model = $next;
            return $model if $quit;
            $self->_render( $model->view );
        }
    }

    return $model;
}

# Simple blocking loop for in-memory handles (no select / subscriptions). Drains
# any inline command results (e.g. a fork-less fallback) each pass.
sub _loop_buffered {
    my ( $self, $model ) = @_;
    while (1) {
        if ( delete $self->{_resized} ) {
            $model = $self->_handle_resize($model);
        }

        my @msgs = @{ delete $self->{_inline_msgs} };
        $self->{_inline_msgs} = [];

        my $bytes = $self->_read_bytes;
        if ( defined $bytes && $bytes ne '' ) {
            push @msgs, $self->_decode($bytes);
        }

        if (@msgs) {
            my ( $next, $quit ) = $self->_apply( $model, @msgs );
            $model = $next;
            return $model if $quit;
            $self->_render( $model->view );
        }

        last unless defined $bytes;    # end-of-input ends the loop cleanly
    }
    return $model;
}

# Fold a batch of messages through update in order. Returns ($model, $quit_flag).
# Any command returned by update is dispatched asynchronously.
sub _apply {
    my ( $self, $model, @msgs ) = @_;
    for my $msg (@msgs) {
        my ( $next, $cmd ) = $model->update($msg);
        return ( $model, 1 )
            if ref $next && $next->isa('PerlTea::Msg::Quit');
        $model = $next if defined $next;
        $self->{model} = $model;
        $self->_dispatch_cmd($cmd) if $cmd;
    }
    return ( $model, 0 );
}

# ── commands (async via fork + pipe + Storable) ──────────────────────────────

# Run a command coderef in a forked child. The value it returns is serialized over
# a pipe and re-enters update when complete, so the loop never blocks on it.
sub _dispatch_cmd {
    my ( $self, $cmd ) = @_;
    return unless $cmd && ref $cmd eq 'CODE';

    my ( $r, $w );
    unless ( pipe( $r, $w ) ) {
        $self->_run_cmd_inline($cmd);
        return;
    }

    my $pid = fork;
    if ( !defined $pid ) {    # fork failed: fall back to synchronous execution
        close $r;
        close $w;
        $self->_run_cmd_inline($cmd);
        return;
    }

    if ( $pid == 0 ) {        # child: compute, serialize, write, _exit
        close $r;
        local $SIG{PIPE} = 'IGNORE';
        my $msg    = eval { $cmd->() };
        my $frozen = eval { Storable::freeze( { m => $msg } ) };
        $frozen = Storable::freeze( { m => undef } ) unless defined $frozen;
        my $frame = pack( 'N', length $frozen ) . $frozen;
        my $off   = 0;
        while ( $off < length $frame ) {
            my $n = syswrite( $w, $frame, length($frame) - $off, $off );
            last unless defined $n;
            $off += $n;
        }
        close $w;
        POSIX::_exit(0);
    }

    close $w;
    my $flags = fcntl( $r, F_GETFL, 0 );
    fcntl( $r, F_SETFL, $flags | O_NONBLOCK ) if defined $flags;
    $self->{_cmds}{ fileno($r) } = { fh => $r, pid => $pid, buf => '' };
    return;
}

# Fork unavailable: run the command in-process and queue its message inline.
sub _run_cmd_inline {
    my ( $self, $cmd ) = @_;
    my $msg = eval { $cmd->() };
    push @{ $self->{_inline_msgs} }, $msg if defined $msg;
    return;
}

# Drain a command pipe that select reported readable; returns any completed
# messages (length-prefixed Storable frames) and reaps the child on EOF.
sub _collect_cmd {
    my ( $self, $fh ) = @_;
    my $entry = $self->{_cmds}{ fileno($fh) } or return ();

    my $chunk = '';
    my $n = sysread( $fh, $chunk, 65536 );
    if ( !defined $n ) {
        return () if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
        $self->_reap_cmd($fh);    # genuine error: give up on this command
        return ();
    }
    $entry->{buf} .= $chunk;

    my @out;
    while ( length $entry->{buf} >= 4 ) {
        my $len = unpack 'N', substr( $entry->{buf}, 0, 4 );
        last if length $entry->{buf} < 4 + $len;
        my $frozen = substr( $entry->{buf}, 4, $len );
        substr( $entry->{buf}, 0, 4 + $len ) = '';
        my $data = eval { Storable::thaw($frozen) };
        push @out, $data->{m} if $data && exists $data->{m} && defined $data->{m};
    }

    $self->_reap_cmd($fh) if $n == 0;    # EOF: child finished
    return @out;
}

sub _reap_cmd {
    my ( $self, $fh ) = @_;
    my $entry = delete $self->{_cmds}{ fileno($fh) } or return;
    close $entry->{fh};
    waitpid( $entry->{pid}, 0 ) if $entry->{pid};
    return;
}

# Tear down any still-running command children (called on every loop exit path).
sub _reap_all_cmds {
    my ($self) = @_;
    for my $fd ( keys %{ $self->{_cmds} || {} } ) {
        my $entry = delete $self->{_cmds}{$fd} or next;
        close $entry->{fh};
        if ( $entry->{pid} ) {
            kill 'TERM', $entry->{pid};
            waitpid( $entry->{pid}, 0 );
        }
    }
    return;
}

# ── subscriptions (timers/streams that feed messages) ────────────────────────

sub _now { return Time::HiRes::time() }

# Snapshot the model's subscription descriptors and schedule their first firing.
sub _init_subs {
    my ( $self, $model ) = @_;
    $self->{_subs} = [];
    return unless $model->can('subscriptions');
    my $subs = $model->subscriptions;
    return unless $subs && ref $subs eq 'ARRAY';

    my $now = $self->_now;
    for my $s (@$subs) {
        next
            unless ref $s eq 'HASH'
            && $s->{every}
            && ref $s->{msg} eq 'CODE';
        push @{ $self->{_subs} },
            {
            every   => $s->{every} + 0,
            msg     => $s->{msg},
            next_at => $now + $s->{every},
            };
    }
    return;
}

# Seconds until the soonest subscription is due (undef = block until I/O).
sub _next_timeout {
    my ($self) = @_;
    return undef unless @{ $self->{_subs} };
    my $now = $self->_now;
    my $min;
    for my $s ( @{ $self->{_subs} } ) {
        my $dt = $s->{next_at} - $now;
        $dt = 0 if $dt < 0;
        $min = $dt if !defined $min || $dt < $min;
    }
    return $min;
}

# Fire every subscription whose interval has elapsed; advance its next firing.
sub _due_sub_msgs {
    my ($self) = @_;
    my @msgs;
    my $now = $self->_now;
    for my $s ( @{ $self->{_subs} } ) {
        next if $now < $s->{next_at};
        my $m = eval { $s->{msg}->() };
        push @msgs, $m if defined $m;
        $s->{next_at} += $s->{every};
        $s->{next_at} = $now + $s->{every} if $s->{next_at} <= $now;
    }
    return @msgs;
}

# ── terminal setup / teardown ────────────────────────────────────────────────

# Cursor / alt-screen control sequences. The diffing renderer (G1) supersedes the
# naive full-frame render below, but the enter/leave sequences stay here.
my $ENTER_ALT  = "\e[?1049h";
my $LEAVE_ALT  = "\e[?1049l";
my $HIDE_CUR   = "\e[?25l";
my $SHOW_CUR   = "\e[?25h";

# Put the controlling terminal into raw mode and hide the cursor (and enter the
# alternate screen if requested). Saves the prior termios so it can be restored.
# When the input handle is not a real tty (tests, pipes) raw mode is skipped, but
# the visible enter/leave sequences are still emitted so teardown is observable.
sub _enter_raw {
    my ($self) = @_;
    my $infd = fileno( $self->{in} );

    if ( defined $infd && $infd >= 0 && -t $self->{in} ) {
        my $saved = POSIX::Termios->new;
        $saved->getattr($infd);
        $self->{_saved_termios} = $saved;
        $self->{_raw_fd}        = $infd;

        my $raw = POSIX::Termios->new;
        $raw->getattr($infd);
        # Local: no echo, no canonical line buffering, no signal/extended chars —
        # we read byte-at-a-time and decode keys ourselves.
        $raw->setlflag( $raw->getlflag & ~( ECHO | ICANON | ISIG | IEXTEN ) );
        # Input: no CR->NL, no flow control, no break/parity meddling.
        $raw->setiflag(
            $raw->getiflag & ~( ICRNL | INPCK | ISTRIP | IXON | BRKINT ) );
        $raw->setcc( VMIN,  1 );    # block for at least one byte
        $raw->setcc( VTIME, 0 );
        $raw->setattr( $infd, TCSANOW );
    }

    $self->_write($ENTER_ALT) if $self->{alt_screen};
    $self->_write($HIDE_CUR);
    return;
}

# Restore the terminal: show the cursor, leave the alt-screen, restore termios.
# Idempotent — safe to call from a signal handler AND the normal exit path.
sub _leave_raw {
    my ($self) = @_;
    return if $self->{_torn_down};
    $self->{_torn_down} = 1;

    $self->_write($SHOW_CUR);
    $self->_write($LEAVE_ALT) if $self->{alt_screen};

    if ( $self->{_saved_termios} ) {
        $self->{_saved_termios}->setattr( $self->{_raw_fd}, TCSANOW );
    }
    return;
}

# ── render / input ───────────────────────────────────────────────────────────

# Keep a previous cell buffer and write only changed cells.
sub _render {
    my ( $self, $view ) = @_;
    $self->_ensure_renderer;
    $self->_write( $self->{_renderer}->render($view) );
    return;
}

sub _ensure_renderer {
    my ($self) = @_;
    return if $self->{_renderer};
    my ( $cols, $rows ) = $self->_terminal_size;
    $self->{_renderer} = PerlTea::Renderer->new( cols => $cols, rows => $rows );
    return;
}

sub _handle_resize {
    my ( $self, $model ) = @_;
    my ( $cols, $rows ) = $self->_terminal_size;
    $self->_ensure_renderer;
    $self->{_renderer}->resize( cols => $cols, rows => $rows );

    if ( $model->can('update') ) {
        my ($next) = $model->update(
            { type => 'resize', width => $cols, height => $rows } );
        $self->{model} = $model = $next
            if defined $next
            && !( ref $next && $next->isa('PerlTea::Msg::Quit') );
    }

    $self->_render( $model->view );
    return $model;
}

sub _terminal_size {
    my ($self) = @_;
    my ( $cols, $rows ) = ( 80, 24 );
    my $out = $self->{out};

    my $ok = eval { require 'sys/ioctl.ph'; 1 };
    if ($ok) {
        my $fd = fileno($out);
        if ( defined $fd && $fd >= 0 ) {
            my $winsize = pack 'S4', 0, 0, 0, 0;
            no strict 'refs';
            if ( defined &{'TIOCGWINSZ'}
                && ioctl( $out, &{'TIOCGWINSZ'}(), $winsize ) )
            {
                my ( $r, $c ) = unpack 'S2', $winsize;
                ( $cols, $rows ) = ( $c, $r ) if $c && $r;
            }
        }
    }

    return ( $cols, $rows );
}

# Lazy input decoder: stateful so escape sequences that span reads are reassembled.
sub _input_decoder {
    my ($self) = @_;
    return $self->{_input} //= PerlTea::Input->new;
}

# Decode a raw input chunk into typed messages via PerlTea::Input.
sub _decode {
    my ( $self, $bytes ) = @_;
    return $self->_input_decoder->feed($bytes);
}

# Read the next available input chunk. Returns the bytes, or undef on end-of-input.
# Uses unbuffered sysread on a real fd (so keypresses arrive immediately) and falls
# back to buffered read for in-memory handles (which PerlIO::scalar can't sysread).
sub _read_bytes {
    my ($self) = @_;
    my $in  = $self->{in};
    my $fd  = fileno($in);
    my $buf = '';

    if ( defined $fd && $fd >= 0 ) {
        while (1) {
            my $n = sysread( $in, $buf, 4096 );
            return $buf if defined $n && $n > 0;
            return undef if defined $n;          # 0 == EOF
            return '' if $!{EINTR} && $self->{_resized};
            next if $!{EINTR};                   # signal interrupted; retry
            return undef;                        # genuine error
        }
    }
    else {
        my $n = read( $in, $buf, 4096 );
        return ( defined $n && $n > 0 ) ? $buf : undef;
    }
}

# Write bytes to the output handle, unbuffered on a real fd. If the string
# contains wide characters (Unicode box-drawing glyphs, etc.) encode it to
# UTF-8 bytes first so syswrite/print never warns and the terminal receives
# valid UTF-8.
sub _write {
    my ( $self, $bytes ) = @_;
    my $out = $self->{out};
    my $fd  = fileno($out);

    $bytes = encode( 'UTF-8', $bytes ) if is_utf8($bytes);

    if ( defined $fd && $fd >= 0 ) {
        # syswrite can short-write; loop until the whole chunk is out.
        my $off = 0;
        while ( $off < length $bytes ) {
            my $n = syswrite( $out, $bytes, length($bytes) - $off, $off );
            last unless defined $n;
            $off += $n;
        }
    }
    else {
        print {$out} $bytes;
    }
    return;
}

package PerlTea::Msg::Quit;

# The sentinel message that tells the runtime to exit its loop.
sub new { return bless {}, shift }

1;

__END__

=head1 NAME

PerlTea::Msg::Quit - sentinel returned from C<update> to end the program

=head2 new

    my $q = PerlTea::Msg::Quit->new;

Create the canonical quit sentinel. Returning this object as the new model from
C<update> ends the event loop.

=cut

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under the
same terms as Perl itself.

=cut
