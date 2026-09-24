package PerlTea::App::Svc;

use strict;
use warnings;

use PerlTea ();
use PerlTea::Component::List ();

=head1 NAME

PerlTea::App::Svc - a small systemd/service manager for PerlTea

=head1 SYNOPSIS

    use PerlTea::App::Svc;
    my $app = PerlTea::App::Svc->new;
    PerlTea->new( model => $app, alt_screen => 1 )->run;

=head1 DESCRIPTION

C<PerlTea::App::Svc> is a service manager modeled on C<systemctl list-units>.
It lists systemd units, lets the user select one, and can start/stop it or show
its recent logs.  For deterministic testing, set C<PERLTEA_SYSTEMCTL_FIXTURE> to
a snapshot of C<systemctl list-units> output; start/stop actions use the
injectable command C<PERLTEA_SYSTEMCTL_CMD> (default C<systemctl>) so the gate
never touches real services.

=cut

=head2 new

    my $app = PerlTea::App::Svc->new;
    my $app = PerlTea::App::Svc->new( fixture => $path, width => 80, height => 24 );

Construct the model.  C<fixture> overrides the environment variable
C<PERLTEA_SYSTEMCTL_FIXTURE>.  Width and height are corrected by the startup
resize message.

=cut

sub new {
    my ( $class, %args ) = @_;

    my $self = bless {
        fixture => exists $args{fixture}
            ? $args{fixture}
            : $ENV{PERLTEA_SYSTEMCTL_FIXTURE},
        width  => $args{width}  || 80,
        height => $args{height} || 24,
        units    => [],
        selected => 0,
        status   => '',
        error    => '',
        mode     => 'list',        # 'list' or 'logs'
        log_lines  => [],
        log_offset => 0,
        log_unit   => '',
    }, $class;

    $self->_load;
    return $self;
}

=head2 init

Return the initial command (none); the constructor loads the first snapshot
synchronously so the first frame is populated.

=cut

sub init { return undef }

=head2 subscriptions

Return a lightweight timer subscription used to refresh the unit list.

=cut

sub subscriptions {
    return [ { every => 10, msg => sub { return { type => 'tick' } } } ];
}

=head2 update

    my ( $model, $cmd ) = $app->update($msg);

Fold a PerlTea message.  C<q>/C<Ctrl-C> quit; C<up>/C<k> and C<down>/C<j> move
the selection; C<s> starts the selected unit; C<x> stops it; C<l> or C<Enter>
shows its recent logs; C<r> refreshes the list.  In log mode, C<Esc> returns to
the list and the arrow keys scroll.

=cut

sub update {
    my ( $self, $msg ) = @_;
    my $type = $msg->{type} // '';

    if ( $type eq 'resize' ) {
        $self->{width}  = $msg->{width}  if $msg->{width};
        $self->{height} = $msg->{height} if $msg->{height};
        return ( $self, undef );
    }

    if ( $type eq 'units_snapshot' ) {
        $self->{units} = $msg->{units} || [];
        $self->{error} = $msg->{error} || '';
        $self->{selected} = 0
            if $self->{selected} > @{ $self->{units} } - 1;
        return ( $self, undef );
    }

    if ( $type eq 'action_done' ) {
        $self->{status} = $msg->{ok}
            ? "$msg->{action} $msg->{unit} ok"
            : "$msg->{action} $msg->{unit} failed: " . ( $msg->{error} || '' );
        return ( $self, undef );
    }

    if ( $type eq 'log_result' ) {
        $self->{log_lines} = $msg->{lines} || [];
        $self->{log_unit}  = $msg->{unit}  || '';
        $self->{log_offset} = 0;
        $self->{mode}      = 'logs';
        return ( $self, undef );
    }

    if ( $type eq 'tick' ) {
        return ( $self, $self->refresh_cmd );
    }

    my $key = $msg->{key} // '';
    return ( PerlTea->quit, undef ) if $key eq 'q' || $key eq 'ctrl+c';

    if ( $self->{mode} eq 'logs' ) {
        if ( $key eq 'esc' ) {
            $self->{mode} = 'list';
            return ( $self, undef );
        }
        if ( $key eq 'up' || $key eq 'k' ) {
            $self->{log_offset}-- if $self->{log_offset} > 0;
            return ( $self, undef );
        }
        if ( $key eq 'down' || $key eq 'j' ) {
            my $max = @{ $self->{log_lines} } - ( $self->{height} - 2 );
            $max = 0 if $max < 0;
            $self->{log_offset}++ if $self->{log_offset} < $max;
            return ( $self, undef );
        }
        return ( $self, undef );
    }

    if ( $key eq 'up' || $key eq 'k' ) {
        $self->{selected}-- if $self->{selected} > 0;
        return ( $self, undef );
    }
    if ( $key eq 'down' || $key eq 'j' ) {
        $self->{selected}++ if $self->{selected} < @{ $self->{units} } - 1;
        return ( $self, undef );
    }

    if ( $key eq 's' && @{ $self->{units} } ) {
        my $unit = $self->{units}[ $self->{selected} ]{unit};
        $self->{status} = "Starting $unit...";
        return ( $self, action_cmd( $unit, 'start' ) );
    }
    if ( $key eq 'x' && @{ $self->{units} } ) {
        my $unit = $self->{units}[ $self->{selected} ]{unit};
        $self->{status} = "Stopping $unit...";
        return ( $self, action_cmd( $unit, 'stop' ) );
    }
    if ( ( $key eq 'l' || $key eq 'enter' ) && @{ $self->{units} } ) {
        my $unit = $self->{units}[ $self->{selected} ]{unit};
        return ( $self, log_cmd($unit) );
    }
    if ( $key eq 'r' ) {
        return ( $self, $self->refresh_cmd );
    }

    return ( $self, undef );
}

=head2 view

Render the unit list or the log view.

=cut

sub view {
    my ($self) = @_;
    my $w = $self->{width}  > 0 ? $self->{width}  : 80;
    my $h = $self->{height} > 3 ? $self->{height} : 4;

    return $self->_view_logs( $w, $h ) if $self->{mode} eq 'logs';
    return $self->_view_list( $w, $h );
}

# ── pure unit engine (unit tested directly) ──────────────────────────────────

=head2 parse_list_units

    my $units = PerlTea::App::Svc::parse_list_units($text);

Parse the text output of C<systemctl list-units> into an arrayref of unit
hashes: C<{ unit, load, active, sub, description }>.  The header line is
recognised and skipped; separator and legend lines are ignored.

=cut

sub parse_list_units {
    my ($text) = @_;
    return [] unless defined $text && length $text;

    my @units;
    my ( $header_seen, %pos );
    for my $line ( split /\n/, $text ) {
        if ( $line =~ /^UNIT\s+LOAD\s+ACTIVE\s+SUB\s+DESCRIPTION/ ) {
            $header_seen = 1;
            $pos{unit}        = index( $line, 'UNIT' );
            $pos{load}        = index( $line, 'LOAD' );
            $pos{active}      = index( $line, 'ACTIVE' );
            $pos{sub}         = index( $line, 'SUB' );
            $pos{description} = index( $line, 'DESCRIPTION' );
            next;
        }
        next unless $header_seen;
        next if $line =~ /^\s*$/;
        next if $line =~ /^(To show|Loaded units listed)/;

        my $unit = _trim( _col( $line, $pos{unit}, $pos{load} ) );
        next unless $unit =~ /\S/;
        next unless $unit =~ /\.[a-zA-Z0-9_-]+\z/;

        push @units, {
            unit        => $unit,
            load        => _trim( _col( $line, $pos{load},   $pos{active} ) ),
            active      => _trim( _col( $line, $pos{active}, $pos{sub} ) ),
            sub         => _trim( _col( $line, $pos{sub},    $pos{description} ) ),
            description => _trim( _col( $line, $pos{description}, undef ) ),
        };
    }
    return \@units;
}

=head2 load_units

    my ( $units, $error ) = PerlTea::App::Svc::load_units(fixture => $path);

Load unit data either from a fixture file or by running
C<systemctl list-units --no-pager>.  Returns C<($units, $error)> where C<$error>
is a human-readable string on failure.

=cut

sub load_units {
    my (%opt) = @_;
    my $fixture = $opt{fixture} // $ENV{PERLTEA_SYSTEMCTL_FIXTURE};

    my ( $text, $error );
    if ( defined $fixture && length $fixture ) {
        open my $fh, '<:encoding(UTF-8)', $fixture
            or return ( [], "cannot open $fixture: $!" );
        local $/;
        $text = <$fh>;
        close $fh;
    }
    else {
        my $cmd = $ENV{PERLTEA_SYSTEMCTL_CMD} // 'systemctl';
        open my $fh, '-|', $cmd, 'list-units', '--no-pager'
            or return ( [], "cannot run $cmd list-units: $!" );
        local $/;
        $text = <$fh>;
        close $fh;
        if ( $? != 0 ) {
            $error = "$cmd list-units exited " . ( $? >> 8 );
        }
    }

    my $units = parse_list_units($text);
    return ( $units, $error // '' );
}

=head2 refresh_cmd

    my $cmd = $app->refresh_cmd;

Return an asynchronous command that reloads the unit list.  The result is
folded back into C<update> as a C<units_snapshot> message.

=cut

sub refresh_cmd {
    my ($self) = @_;
    my $fixture = $self->{fixture};
    return sub {
        my ( $units, $error ) = load_units( fixture => $fixture );
        return { type => 'units_snapshot', units => $units, error => $error };
    };
}

=head2 action_cmd

    my $cmd = PerlTea::App::Svc::action_cmd($unit, $action);

Return an asynchronous command that invokes C<PERLTEA_SYSTEMCTL_CMD> (default
C<systemctl>) with C<$action> and C<$unit>.  The result is folded back into
C<update> as an C<action_done> message.

=cut

sub action_cmd {
    my ( $unit, $action ) = @_;
    return sub {
        my $cmd = $ENV{PERLTEA_SYSTEMCTL_CMD} // 'systemctl';
        system $cmd, $action, $unit;
        my $ok = $? == 0 ? 1 : 0;
        return {
            type   => 'action_done',
            unit   => $unit,
            action => $action,
            ok     => $ok,
            error  => $ok ? '' : "$cmd $action $unit exited " . ( $? >> 8 ),
        };
    };
}

=head2 log_cmd

    my $cmd = PerlTea::App::Svc::log_cmd($unit);

Return an asynchronous command that fetches the last 200 log lines for
C<$unit> via C<journalctl>.  The result is folded back into C<update> as a
C<log_result> message.

=cut

sub log_cmd {
    my ($unit) = @_;
    return sub {
        my $cmd = $ENV{PERLTEA_SYSTEMCTL_CMD} // 'systemctl';
        my $out = '';
        if ( open my $fh, '-|', 'journalctl', '-u', $unit, '-n', '200', '--no-pager' ) {
            local $/;
            $out = <$fh> // '';
            close $fh;
        }
        else {
            $out = "cannot run journalctl: $!";
        }
        my @lines = split /\n/, $out, -1;
        @lines = ('') unless @lines;
        return { type => 'log_result', unit => $unit, lines => \@lines };
    };
}

# ── internals ────────────────────────────────────────────────────────────────

sub _load {
    my ($self) = @_;
    my ( $units, $error ) = load_units( fixture => $self->{fixture} );
    $self->{units} = $units;
    $self->{error} = $error // '';
    $self->{selected} = 0 if $self->{selected} > @{ $self->{units} } - 1;
    return;
}

sub _view_list {
    my ( $self, $w, $h ) = @_;
    my @out;
    my $header = 'Services - ' . scalar( @{ $self->{units} } ) . ' units';
    push @out, _fit( $header, $w );

    my $status_line = '';
    if ( length $self->{error} ) {
        $status_line = 'Error: ' . $self->{error};
    }
    elsif ( length $self->{status} ) {
        $status_line = $self->{status};
    }
    push @out, _fit( $status_line, $w ) if length $status_line;

    my $used = @out + 1;    # +1 for the footer line
    my $list_h = $h - $used;
    $list_h = 0 if $list_h < 0;

    if ( $list_h > 0 && @{ $self->{units} } ) {
        my @items = map { _format_unit( $_, $w - 2 ) } @{ $self->{units} };
        my $list = PerlTea::Component::List->new(
            items    => \@items,
            width    => $w,
            height   => $list_h,
            selected => $self->{selected},
            focus    => 1,
        );
        push @out, split /\n/, $list->view;
    }
    elsif ( $list_h > 0 ) {
        push @out, _fit( 'No units loaded.', $w );
    }

    push @out, '' while @out < $h - 1;
    push @out,
        _fit( 'q: quit  up/down: select  s: start  x: stop  l: logs  r: refresh', $w );

    return join "\n", @out;
}

sub _view_logs {
    my ( $self, $w, $h ) = @_;
    my @out;
    push @out, _fit( 'Logs for ' . $self->{log_unit}, $w );

    my $visible_h = $h - 2;
    $visible_h = 1 if $visible_h < 1;

    my $max = @{ $self->{log_lines} } - $visible_h;
    $max = 0 if $max < 0;
    $self->{log_offset} = $max if $self->{log_offset} > $max;

    my $start = $self->{log_offset};
    for my $i ( 0 .. $visible_h - 1 ) {
        my $idx  = $start + $i;
        my $line = $idx < @{ $self->{log_lines} } ? $self->{log_lines}[$idx] : '';
        push @out, _fit( $line, $w );
    }

    push @out, _fit( 'Esc: back  up/down: scroll', $w );
    return join "\n", @out;
}

sub _format_unit {
    my ( $unit, $width ) = @_;
    my $uw = 25;
    my $aw = 8;
    my $sw = 8;
    my $dw = $width - $uw - $aw - $sw - 3;
    $dw = 5 if $dw < 5;

    my $u = $unit->{unit};
    my $a = $unit->{active};
    my $s = $unit->{sub};
    my $d = $unit->{description};

    $u = substr( $u, 0, $uw ) if length($u) > $uw;
    $a = substr( $a, 0, $aw ) if length($a) > $aw;
    $s = substr( $s, 0, $sw ) if length($s) > $sw;
    $d = substr( $d, 0, $dw ) if length($d) > $dw;

    return sprintf( "%-${uw}s %-${aw}s %-${sw}s %s", $u, $a, $s, $d );
}

sub _fit {
    my ( $line, $width ) = @_;
    $line = '' unless defined $line;
    $line = substr( $line, 0, $width ) if length($line) > $width;
    return $line . ( ' ' x ( $width - length($line) ) );
}

sub _trim {
    my ($s) = @_;
    $s =~ s/^\s+|\s+\z//g;
    return $s;
}

sub _col {
    my ( $line, $start, $end ) = @_;
    return '' unless defined $start && $start >= 0;
    $end = length($line) if !defined $end;
    my $len = $end - $start;
    $len = length($line) - $start if $start + $len > length($line);
    return $len > 0 ? substr( $line, $start, $len ) : '';
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
