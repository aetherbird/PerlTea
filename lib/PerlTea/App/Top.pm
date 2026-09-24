package PerlTea::App::Top;

use strict;
use warnings;

use PerlTea ();
use PerlTea::Style ();
use PerlTea::Component::List ();
use PerlTea::Component::TextInput ();

=head1 NAME

PerlTea::App::Top - a small htop-style process viewer for PerlTea

=head1 SYNOPSIS

    use PerlTea::App::Top;
    my $app = PerlTea::App::Top->new;
    PerlTea->new( model => $app, alt_screen => 1 )->run;

=head1 DESCRIPTION

C<PerlTea::App::Top> is a live-sorting process list. By default it runs
C<ps aux> to collect processes; set C<PERLTEA_PS_FIXTURE> to a snapshot file for
deterministic offline operation. Processes are sorted by CPU usage, and a
C</> filter narrows the list. The kill action uses C<PERLTEA_KILL_CMD>
(default C<kill>) so tests never have to touch real processes.

=cut

=head2 new

    my $app = PerlTea::App::Top->new;
    my $app = PerlTea::App::Top->new( fixture => $path, width => 80, height => 24 );

Construct the model. C<fixture> overrides the environment variable
C<PERLTEA_PS_FIXTURE>. Width and height are corrected by the startup resize
message.

=cut

sub new {
    my ( $class, %args ) = @_;

    my $self = bless {
        fixture      => exists $args{fixture} ? $args{fixture} : $ENV{PERLTEA_PS_FIXTURE},
        width        => $args{width}  || 80,
        height       => $args{height} || 24,
        processes    => [],
        filtered     => [],
        selected     => 0,
        filter_mode  => 0,
        active_filter => '',
        status       => '',
        error        => '',
    }, $class;

    $self->_refresh_input;
    $self->_load;
    return $self;
}

=head2 init

Return the initial command (none); the constructor loads the first snapshot
synchronously so the first frame is populated.

=cut

sub init { return undef }

=head2 subscriptions

Return a lightweight timer subscription used to refresh the process list.

=cut

sub subscriptions {
    return [ { every => 2, msg => sub { return { type => 'tick' } } } ];
}

=head2 update

    my ( $model, $cmd ) = $app->update($msg);

Fold a PerlTea message. C<q>/C<Ctrl-C> quit; C</> opens the filter prompt;
C<Enter> applies a filter; C<Esc> cancels it; arrow keys or C<j>/C<k> move the
selection; C<k> kills the selected process asynchronously.

=cut

sub update {
    my ( $self, $msg ) = @_;
    my $type = $msg->{type} // '';

    if ( $type eq 'resize' ) {
        $self->{width}  = $msg->{width}  if $msg->{width};
        $self->{height} = $msg->{height} if $msg->{height};
        $self->_refresh_input;
        return ( $self, undef );
    }

    if ( $type eq 'ps_snapshot' ) {
        $self->{error}     = $msg->{error} || '';
        $self->{processes} = $msg->{processes} || [];
        $self->_apply_filter;
        return ( $self, undef );
    }

    if ( $type eq 'kill_done' ) {
        $self->{status} = $msg->{ok}
            ? 'Killed pid ' . $msg->{pid}
            : 'Kill failed: ' . ( $msg->{error} || $msg->{pid} );
        return ( $self, undef );
    }

    if ( $type eq 'tick' ) {
        return ( $self, $self->refresh_cmd );
    }

    my $key = $msg->{key} // '';
    return ( PerlTea->quit, undef ) if $key eq 'q' || $key eq 'ctrl+c';

    if ( $self->{filter_mode} ) {
        if ( $key eq 'enter' ) {
            $self->{active_filter} = $self->{filter_input}->value;
            $self->{filter_mode}   = 0;
            $self->{selected}      = 0;
            $self->_apply_filter;
            return ( $self, undef );
        }
        if ( $key eq 'esc' ) {
            $self->{filter_mode} = 0;
            $self->_refresh_input;
            return ( $self, undef );
        }
        $self->{filter_input}->handle_msg($msg);
        return ( $self, undef );
    }

    if ( $key eq '/' ) {
        $self->{filter_mode} = 1;
        $self->{active_filter} = '';
        $self->_refresh_input;
        return ( $self, undef );
    }

    if ( $key eq 'up' || $key eq 'k' ) {
        $self->{selected}-- if $self->{selected} > 0;
        return ( $self, undef );
    }
    if ( $key eq 'down' || $key eq 'j' ) {
        $self->{selected}++ if $self->{selected} < @{ $self->{filtered} } - 1;
        return ( $self, undef );
    }
    if ( $key eq 'k' && @{ $self->{filtered} } ) {
        my $proc = $self->{filtered}[ $self->{selected} ];
        $self->{status} = 'Killing pid ' . $proc->{pid} . '...';
        return ( $self, kill_cmd( $proc->{pid} ) );
    }

    return ( $self, undef );
}

=head2 view

Render the header, filter prompt or status, the process list, and a help footer.

=cut

sub view {
    my ($self) = @_;
    my $w = $self->{width}  > 0 ? $self->{width}  : 80;
    my $h = $self->{height} > 4 ? $self->{height} : 5;

    my @out;
    my $total  = scalar @{ $self->{processes} };
    my $shown  = scalar @{ $self->{filtered} };
    my $header = "Top - $shown/$total processes";
    if ( length $self->{active_filter} ) {
        $header .= " matching '" . $self->{active_filter} . "'";
    }
    push @out, _fit( $header, $w );

    if ( $self->{filter_mode} ) {
        push @out, _fit( 'Filter: ' . $self->{filter_input}->view, $w );
    }
    elsif ( length $self->{status} ) {
        push @out, _fit( $self->{status}, $w );
    }
    elsif ( length $self->{error} ) {
        push @out, _fit( 'Error: ' . $self->{error}, $w );
    }

    my $footer = 'q: quit   /: filter   k: kill   up/down: select';

    # Column-header row, aligned to the list rows below (which the List
    # component indents by a two-character cursor + space prefix).
    my $col_header = _column_header($w);

    my $used   = @out + 1 + 1;    # +1 footer, +1 column header
    my $list_h = $h - $used;
    $list_h = 0 if $list_h < 0;

    push @out, $col_header;

    if ( $list_h > 0 ) {
        my @items = map { _format_row( $_, $w - 2 ) } @{ $self->{filtered} };
        my $list = PerlTea::Component::List->new(
            items    => \@items,
            width    => $w,
            height   => $list_h,
            selected => $self->{selected},
            focus    => 1,
        );
        push @out, split /\n/, $list->view;
    }

    push @out, '' while @out < $h - 1;
    push @out, _fit( $footer, $w );

    return join "\n", @out;
}

# ── pure process engine (unit tested directly) ───────────────────────────────

=head2 parse_ps_text

    my $procs = PerlTea::App::Top::parse_ps_text($ps_output);

Parse the text output of C<ps aux> (or the fixture file) into an arrayref of
process hashes: C<{ user, pid, cpu, mem, vsz, rss, tty, stat, start, time,
command }>. The header line is recognised and skipped; CPU and memory values are
converted to numbers.

=cut

sub parse_ps_text {
    my ($text) = @_;
    return [] unless defined $text && length $text;

    my @procs;
    my $header_seen = 0;
    for my $line ( split /\n/, $text ) {
        next if $line =~ /^\s*$/;
        if ( !$header_seen && $line =~ /^USER\s+PID\s+/ ) {
            $header_seen = 1;
            next;
        }
        $line =~ s/^\s+//;
        my @f = split /\s+/, $line, 11;
        next if @f < 11;
        my ( $user, $pid, $cpu, $mem, $vsz, $rss, $tty, $stat, $start, $time, $command ) = @f;
        push @procs, {
            user    => $user,
            pid     => $pid + 0,
            cpu     => $cpu + 0,
            mem     => $mem + 0,
            vsz     => $vsz,
            rss     => $rss,
            tty     => $tty,
            stat    => $stat,
            start   => $start,
            time    => $time,
            command => $command,
        };
    }
    return \@procs;
}

=head2 sort_processes

    my $sorted = PerlTea::App::Top::sort_processes($procs);

Return a new arrayref sorted by CPU descending, with PID as a stable tie-breaker.

=cut

sub sort_processes {
    my ($procs) = @_;
    return [] unless $procs && @$procs;
    return [
        sort {
            $b->{cpu} <=> $a->{cpu}
                || $a->{pid} <=> $b->{pid}
        } @$procs
    ];
}

=head2 filter_processes

    my $narrowed = PerlTea::App::Top::filter_processes($procs, $term);

Return a new arrayref containing only processes whose command line, user, or
PID matches C<$term> (case-insensitive). An empty or undefined term returns the
original list unchanged.

=cut

sub filter_processes {
    my ( $procs, $term ) = @_;
    return $procs unless defined $term && length $term;
    my $re = eval { qr/\Q$term\E/i };
    return $procs if $@;
    return [
        grep {
            $_->{command} =~ $re
                || $_->{user} =~ $re
                || index( $_->{pid}, $term ) >= 0
        } @$procs
    ];
}

=head2 load_processes

    my ( $procs, $error ) = PerlTea::App::Top::load_processes(fixture => $path);

Load process data either from a fixture file or by running C<ps aux>. Returns
C<($procs, $error)> where C<$error> is a human-readable string on failure.

=cut

sub load_processes {
    my (%opt) = @_;
    my $fixture = $opt{fixture} // $ENV{PERLTEA_PS_FIXTURE};

    my ( $text, $error );
    if ( defined $fixture && length $fixture ) {
        open my $fh, '<:encoding(UTF-8)', $fixture
            or return ( [], "cannot open $fixture: $!" );
        local $/;
        $text = <$fh>;
        close $fh;
    }
    else {
        my $cmd = $ENV{PERLTEA_PS_CMD} // 'ps aux';
        open my $fh, '-|', $cmd
            or return ( [], "cannot run $cmd: $!" );
        local $/;
        $text = <$fh>;
        close $fh;
        if ( $? != 0 ) {
            $error = "$cmd exited " . ( $? >> 8 );
        }
    }

    my $procs = parse_ps_text($text);
    return ( $procs, $error // '' );
}

=head2 refresh_cmd

    my $cmd = $app->refresh_cmd;

Return an asynchronous command that reloads the process list. The result is
folded back into C<update> as a C<ps_snapshot> message.

=cut

sub refresh_cmd {
    my ($self) = @_;
    my $fixture = $self->{fixture};
    return sub {
        my ( $procs, $error ) = load_processes( fixture => $fixture );
        return { type => 'ps_snapshot', processes => $procs, error => $error };
    };
}

=head2 kill_cmd

    my $cmd = PerlTea::App::Top::kill_cmd($pid);

Return an asynchronous command that invokes C<PERLTEA_KILL_CMD> (default
C<kill>) on C<$pid>. The result is folded back into C<update> as a
C<kill_done> message.

=cut

sub kill_cmd {
    my ($pid) = @_;
    return sub {
        my $cmd = $ENV{PERLTEA_KILL_CMD} // 'kill';
        system $cmd, $pid;
        my $ok = $? == 0 ? 1 : 0;
        return {
            type  => 'kill_done',
            pid   => $pid,
            ok    => $ok,
            error => $ok ? '' : "$cmd exited " . ( $? >> 8 ),
        };
    };
}

# ── internals ───────────────────────────────────────────────────────────────

sub _load {
    my ($self) = @_;
    my ( $procs, $error ) = load_processes( fixture => $self->{fixture} );
    $self->{processes} = $procs;
    $self->{error}     = $error // '';
    $self->_apply_filter;
    return;
}

sub _apply_filter {
    my ($self) = @_;
    my $filtered = filter_processes( $self->{processes}, $self->{active_filter} );
    $self->{filtered} = sort_processes($filtered);
    $self->{selected} = 0 if $self->{selected} > @{ $self->{filtered} } - 1;
    $self->{selected} = 0 if $self->{selected} < 0;
    return;
}

sub _refresh_input {
    my ($self) = @_;
    my $iw = $self->{width} - 9;
    $iw = 1 if $iw < 1;
    my $value = $self->{filter_input} ? $self->{filter_input}->value : '';
    $self->{filter_input} = PerlTea::Component::TextInput->new(
        width       => $iw,
        value       => $value,
        focus       => 1,
        placeholder => 'filter',
    );
    return;
}

sub _column_header {
    my ($width) = @_;
    $width = 1 if !defined $width || $width < 1;

    # The list rows are formatted by _format_row as
    #   sprintf '%6d %-8s %5s %5s %s'  (pid, user, cpu, mem, command)
    # and the List component then indents each row with a two-character
    # cursor + space prefix. Mirror both exactly so the labels line up
    # over their columns.
    my $labels = sprintf( '%6s %-8s %5s %5s %s',
        'PID', 'USER', '%CPU', '%MEM', 'COMMAND' );
    my $line = '  ' . $labels;

    my $style = PerlTea::Style->new(
        width => $width,
        bold  => 1,
        faint => 1,
        align => 'left',
    );
    return $style->render($line);
}

sub _format_row {
    my ( $proc, $width ) = @_;
    my $user    = $proc->{user};
    my $command = $proc->{command};
    my $cpu     = sprintf '%.1f', $proc->{cpu};
    my $mem     = sprintf '%.1f', $proc->{mem};

    my $cmd_w = $width - 27;
    $cmd_w = 5 if $cmd_w < 5;
    $user    = substr( $user, 0, 8 )       if length($user) > 8;
    $command = substr( $command, 0, $cmd_w ) if length($command) > $cmd_w;

    my $line = sprintf( '%6d %-8s %5s %5s %s',
        $proc->{pid}, $user, $cpu, $mem, $command );
    return $line;
}

sub _fit {
    my ( $line, $width ) = @_;
    $line = '' unless defined $line;
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
