#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;

# G0 demo — a counter. It proves the event loop and, above all, that the terminal
# is restored on EVERY exit path:
#   * 'q'  quits cleanly (the loop ends, run() restores the terminal, exit 0).
#   * 'p'  triggers a deliberate uncaught die — the framework must still restore
#          the terminal before the process exits non-zero.
#   * any other key bumps the counter and repaints.
# No absolute coordinates, no manual raw-mode handling: the framework owns all of it.

package Counter;

sub new { return bless { count => 0 }, shift }

sub init { return undef }

sub update {
    my ( $self, $msg ) = @_;
    my $key = defined $msg->{key} ? $msg->{key} : '';

    return ( PerlTea->quit, undef ) if $key eq 'q';
    die "PerlTea g0 demo: deliberate panic ('p') to exercise the restore path\n"
        if $key eq 'p';

    $self->{count}++;
    return ( $self, undef );
}

sub view {
    my ($self) = @_;
    return
          "PerlTea G0 — counter\r\n"
        . "count: $self->{count}\r\n"
        . "\r\n"
        . "any key = +1   q = quit   p = panic (tests teardown)\r\n";
}

package main;

PerlTea->new( model => Counter->new, alt_screen => 1 )->run;
