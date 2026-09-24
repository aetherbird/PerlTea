#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;

# G3 demo — commands & subscriptions. Proves the loop never blocks:
#   * a CLOCK subscription ticks several times a second (visible, no input needed);
#   * a background-task COMMAND (returned from init) sleeps, then posts a "done"
#     message that re-enters update — all while the keyboard stays responsive.
# The gate lets the clock tick, presses a key, then quits with 'q'.

package ClockTask;

sub new {
    return bless {
        ticks => 0,
        time  => _hhmmss(),
        task  => 'running…',
        log   => [],
    }, shift;
}

# Initial command: a background task. It runs asynchronously in a forked child,
# sleeps (~0.5s) to stand in for slow work, then returns a message. The loop stays
# responsive the whole time; the message re-enters update when the task finishes.
sub init {
    return sub {
        select( undef, undef, undef, 0.5 );    # fractional sleep, core-only
        return { type => 'taskdone', result => 42 };
    };
}

# The clock: a timer subscription firing ~5x/second.
sub subscriptions {
    return [ { every => 0.2, msg => sub { return { type => 'tick' } } } ];
}

sub update {
    my ( $self, $msg ) = @_;
    my $type = $msg->{type} // '';

    if ( $type eq 'tick' ) {
        $self->{ticks}++;
        $self->{time} = _hhmmss();
    }
    elsif ( $type eq 'taskdone' ) {
        $self->{task} = "done (result=$msg->{result})";
    }
    elsif ( $type eq 'key' ) {
        my $key = $msg->{key} // '';
        return ( PerlTea->quit, undef ) if $key eq 'q';
        push @{ $self->{log} }, $key;
        splice @{ $self->{log} }, 0, -5 if @{ $self->{log} } > 5;
    }

    return ( $self, undef );
}

sub view {
    my ($self) = @_;
    return join "\n",
        'PerlTea G3 — commands & subscriptions',
        "clock: $self->{time}   ticks=$self->{ticks}",
        "task:  $self->{task}",
        'keys:  ' . join( ' ', @{ $self->{log} } ),
        'press keys; q to quit';
}

sub _hhmmss {
    my ( $s, $m, $h ) = ( localtime )[ 0, 1, 2 ];
    return sprintf '%02d:%02d:%02d', $h, $m, $s;
}

package main;

PerlTea->new( model => ClockTask->new, alt_screen => 1 )->run;
