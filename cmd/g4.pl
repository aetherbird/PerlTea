#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;
use PerlTea::Style;

# G4 demo — declarative styling. Renders a bordered, padded, colored, aligned box
# and bumps a counter on every keypress. 'q' quits. Proves PerlTea::Style emits
# real ANSI SGR sequences and that the diffing renderer handles them.

package G4Demo;

sub new {
    return bless { count => 0 }, shift;
}

sub init { return undef }

sub update {
    my ( $self, $msg ) = @_;
    return ( PerlTea->quit, undef ) if $msg->{key} && $msg->{key} eq 'q';
    $self->{count}++;
    return ( $self, undef );
}

sub view {
    my ($self) = @_;

    my $box = PerlTea::Style->new(
        border         => 'single',
        padding        => [ 1, 2 ],
        width          => 42,
        height         => 9,
        align          => 'center',
        vertical_align => 'middle',
        foreground     => '#e0e0e0',
        background     => '#2a0a4a',
        bold           => 1,
    )->render("PerlTea G4\nStyling demo\ncount: $self->{count}");

    return $box;
}

package main;

PerlTea->new( model => G4Demo->new, alt_screen => 1 )->run;
