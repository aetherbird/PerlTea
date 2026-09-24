package PerlTea::App::Watch;

use strict;
use warnings;

use PerlTea ();
use POSIX ();

=head1 NAME

PerlTea::App::Watch - a TUI watch(1): re-run a command on an interval and
diff-highlight what changed

=head1 SYNOPSIS

    use PerlTea::App::Watch;
    my $app = PerlTea::App::Watch->new(
        command  => [ 'date', '+%T' ],
        interval => 1,
    );
    PerlTea->new( model => $app, alt_screen => 1 )->run;

=head1 DESCRIPTION

C<PerlTea::App::Watch> repeatedly runs a command (like the Unix C<watch(1)>
utility) and displays its latest output, highlighting the lines that changed
since the previous run in reverse video. The command runs asynchronously inside
a PerlTea command so the UI loop never blocks; a timer subscription schedules
each re-run on the requested interval.

=cut

=head2 new

    my $app = PerlTea::App::Watch->new( command => \@argv, interval => $secs );

Construct the model. C<command> is an arrayref of the command and its arguments
(run without a shell). C<interval> is the re-run period in (possibly fractional)
seconds; it defaults to 2. Width and height are corrected by the startup resize
message.

=cut

sub new {
    my ( $class, %args ) = @_;

    my $interval = defined $args{interval} ? $args{interval} + 0 : 2;
    $interval = 0.1 if $interval <= 0;

    my $self = bless {
        command  => $args{command} || [],
        interval => $interval,
        width    => $args{width}  || 80,
        height   => $args{height} || 24,
        prev     => undef,    # output of the previous run (undef until 2nd run)
        current  => undef,    # output of the most recent run
        exit     => undef,    # exit code of the most recent run
        runs     => 0,        # how many times the command has completed
    }, $class;

    return $self;
}

=head2 init

Kick off the first run immediately so the first frame is populated as soon as the
command returns.

=cut

sub init {
    my ($self) = @_;
    return $self->run_cmd;
}

=head2 subscriptions

Return a single timer subscription that fires a C<tick> message every
C<interval> seconds; each tick re-runs the watched command.

=cut

sub subscriptions {
    my ($self) = @_;
    return [ { every => $self->{interval}, msg => sub { return { type => 'tick' } } } ];
}

=head2 update

    my ( $model, $cmd ) = $app->update($msg);

Fold a PerlTea message. C<q>/C<Ctrl-C> quit; a C<tick> re-runs the command; a
C<run_result> stores the new output (rotating the previous one for diffing).

=cut

sub update {
    my ( $self, $msg ) = @_;
    my $type = $msg->{type} // '';

    if ( $type eq 'resize' ) {
        $self->{width}  = $msg->{width}  if $msg->{width};
        $self->{height} = $msg->{height} if $msg->{height};
        return ( $self, undef );
    }

    if ( $type eq 'tick' ) {
        return ( $self, $self->run_cmd );
    }

    if ( $type eq 'run_result' ) {
        # Rotate: the output we just had becomes "previous" for the next diff.
        $self->{prev}    = $self->{current};
        $self->{current} = defined $msg->{output} ? $msg->{output} : '';
        $self->{exit}    = $msg->{exit};
        $self->{runs}++;
        return ( $self, undef );
    }

    my $key = $msg->{key} // '';
    return ( PerlTea->quit, undef ) if $key eq 'q' || $key eq 'ctrl+c';

    return ( $self, undef );
}

=head2 view

Render a header (interval, command, run count) followed by the latest command
output, diff-highlighted against the previous run.

=cut

sub view {
    my ($self) = @_;
    my $w = $self->{width}  > 0 ? $self->{width}  : 80;
    my $h = $self->{height} > 2 ? $self->{height} : 3;

    my @out;
    my $cmd_str = join ' ', @{ $self->{command} };
    my $header  = sprintf 'Every %ss: %s', _trim_num( $self->{interval} ), $cmd_str;
    $header .= "   (runs: $self->{runs})" if $self->{runs};
    if ( defined $self->{exit} && $self->{exit} != 0 ) {
        $header .= "   [exit $self->{exit}]";
    }
    push @out, _fit( $header, $w );

    my $body;
    if ( !defined $self->{current} ) {
        $body = 'Waiting for first run...';
    }
    elsif ( !defined $self->{prev} ) {
        # First completed run: nothing to diff against, show it plainly so the
        # diffing renderer paints the whole line contiguously.
        $body = $self->{current};
    }
    else {
        $body = highlight_diff( $self->{prev}, $self->{current} );
    }

    push @out, map { _fit( $_, $w ) } split /\n/, $body, -1;

    # Pad to height; reserve nothing special at the bottom.
    push @out, _fit( '', $w ) while @out < $h;
    @out = @out[ 0 .. $h - 1 ] if @out > $h;

    return join "\n", @out;
}

# ── pure diff/run engine (unit tested directly) ──────────────────────────────

=head2 run_command

    my ( $output, $exit ) = PerlTea::App::Watch::run_command(\@argv);

Run C<@argv> with no shell, capturing combined STDOUT+STDERR. Returns the
captured text and the command's exit code (C<-1> if it could not be launched).

=cut

sub run_command {
    my ($argv) = @_;
    return ( '', -1 ) unless $argv && @$argv;

    my $pid = open my $fh, '-|';
    if ( !defined $pid ) {
        return ( "watch: cannot fork: $!\n", -1 );
    }
    if ( $pid == 0 ) {
        # child: merge stderr into stdout, then exec the watched command.
        open STDERR, '>&', \*STDOUT;
        { exec { $argv->[0] } @$argv; }
        print "watch: cannot exec $argv->[0]: $!\n";
        POSIX::_exit(127);
    }

    local $/;
    my $out = <$fh>;
    close $fh;
    my $exit = $? >> 8;
    return ( defined $out ? $out : '', $exit );
}

=head2 highlight_diff

    my $marked = PerlTea::App::Watch::highlight_diff($prev, $cur);

Compare C<$cur> against C<$prev> line by line and return C<$cur> with every line
that differs from (or is new relative to) the previous output wrapped in reverse
video (C<\e[7m> ... C<\e[27m>). Unchanged lines are returned untouched, so
identical inputs yield no SGR at all. Whole lines are highlighted (not sub-spans)
so a changed value renders as one contiguous run.

=cut

sub highlight_diff {
    my ( $prev, $cur ) = @_;
    $prev = '' unless defined $prev;
    $cur  = '' unless defined $cur;

    # Drop a single trailing newline so a command's "x\n" does not produce a
    # spurious blank highlighted line.
    $prev =~ s/\n\z//;
    $cur  =~ s/\n\z//;

    my @p = split /\n/, $prev, -1;
    my @c = split /\n/, $cur,  -1;

    my @out;
    for my $i ( 0 .. $#c ) {
        my $line = $c[$i];
        my $old  = $i <= $#p ? $p[$i] : undef;
        if ( !defined $old || $old ne $line ) {
            push @out, "\e[7m" . $line . "\e[27m";
        }
        else {
            push @out, $line;
        }
    }
    return join "\n", @out;
}

=head2 run_cmd

    my $cmd = $app->run_cmd;

Return an asynchronous PerlTea command that runs the watched command and folds
its output back into C<update> as a C<run_result> message.

=cut

sub run_cmd {
    my ($self) = @_;
    my $argv = $self->{command};
    return sub {
        my ( $output, $exit ) = run_command($argv);
        return { type => 'run_result', output => $output, exit => $exit };
    };
}

=head2 parse_args

    my ( $interval, $argv, $err ) = PerlTea::App::Watch::parse_args(@argv);

Parse C<--interval N -- cmd ...> style arguments. Returns the interval (default
2), an arrayref with the command and its arguments, and an error string (empty
on success). C<--interval=N> and the short C<-n N> are also accepted.

=cut

sub parse_args {
    my @args = @_;
    my $interval = 2;
    my @cmd;
    my $err = '';

    while (@args) {
        my $a = shift @args;
        if ( $a eq '--' ) {
            @cmd = @args;
            last;
        }
        elsif ( $a eq '--interval' || $a eq '-n' ) {
            $interval = shift @args;
            $err = 'missing value for --interval' unless defined $interval;
        }
        elsif ( $a =~ /^--interval=(.+)\z/ ) {
            $interval = $1;
        }
        elsif ( $a =~ /^-/ ) {
            $err = "unknown option $a";
        }
        else {
            # Bare command form: everything from here is the command.
            @cmd = ( $a, @args );
            last;
        }
    }

    $err = 'no command given' unless @cmd || $err;
    return ( $interval, \@cmd, $err );
}

# ── internals ────────────────────────────────────────────────────────────────

sub _fit {
    my ( $line, $width ) = @_;
    $line = '' unless defined $line;
    # Visible-length aware so embedded SGR (the diff highlight) does not count.
    my $vis = $line;
    $vis =~ s/\e\[[0-9;]*m//g;
    my $len = length $vis;
    if ( $len > $width ) {
        # Truncate on visible characters while keeping escapes intact is complex;
        # for watch output a plain substr of the de-escaped fallback is enough.
        $line = substr( $vis, 0, $width );
        $len  = $width;
    }
    return $line . ( ' ' x ( $width - $len ) );
}

sub _trim_num {
    my ($n) = @_;
    my $s = sprintf '%g', $n;
    return $s;
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
