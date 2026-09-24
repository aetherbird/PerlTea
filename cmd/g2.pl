#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;

# G2 demo — key echo. Proves the input decoder by naming every key it receives.
# The gate drives it with an Up arrow, a Ctrl-combo, and a bracketed paste, then
# quits with 'q'. Each input is rendered as a human-readable line containing the
# key name (e.g. "up", "ctrl+a", "paste").

package KeyEcho;

sub new {
    return bless { lines => [], max => 12 }, shift;
}

sub init { return undef }

sub update {
    my ( $self, $msg ) = @_;

    if ( $msg->{type} && $msg->{type} eq 'paste' ) {
        push @{ $self->{lines} },
            'paste: ' . length( $msg->{text} ) . ' bytes';
    }
    elsif ( $msg->{type} && $msg->{type} eq 'key' ) {
        my $name = $msg->{key} // '?';
        return ( PerlTea->quit, undef ) if $name eq 'q';
        push @{ $self->{lines} }, "key: $name";
    }

    # Keep only the most recent lines so the view stays compact.
    splice @{ $self->{lines} }, 0, -$self->{max}
        if @{ $self->{lines} } > $self->{max};

    return ( $self, undef );
}

sub view {
    my ($self) = @_;
    return join "\n",
        'PerlTea G2 — key echo',
        'press keys; q to quit',
        @{ $self->{lines} };
}

package main;

PerlTea->new( model => KeyEcho->new, alt_screen => 1 )->run;
