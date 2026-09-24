#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use PerlTea;
use Time::HiRes qw(usleep);

{
    package G1Demo;

    sub new {
        return bless { tick => 0, width => 80, height => 24 }, shift;
    }

    sub init { return undef }

    sub update {
        my ( $self, $msg ) = @_;
        return ( PerlTea->quit, undef ) if $msg->{key} && $msg->{key} eq 'q';
        if ( $msg->{type} && $msg->{type} eq 'resize' ) {
            $self->{width}  = $msg->{width};
            $self->{height} = $msg->{height};
        }
        $self->{tick}++;
        Time::HiRes::usleep(20_000);
        return ( $self, undef );
    }

    sub view {
        my ($self) = @_;
        my $bar = '=' x ( ( $self->{tick} % 20 ) + 1 );
        return join "\n",
            'PerlTea G1 diffing renderer',
            'tick: ' . $self->{tick},
            'size: ' . $self->{width} . 'x' . $self->{height},
            '[' . $bar . '>',
            'press q to quit';
    }
}

PerlTea->new( model => G1Demo->new, alt_screen => 1 )->run;
