#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;
use PerlTea::App::GitDash;

# D3 demo — git dashboard live + actions. Renders the multi-pane dashboard for
# the current repo (or a path given as the first argument). Tab cycles focus,
# r triggers an asynchronous refresh (the git commands run off the event loop so
# the UI never freezes — even while a slow refresh is in flight), and q quits.
#
# Set PERLTEA_GATE_SLOWGIT=1 to make each refresh deliberately slow; the loop
# must stay responsive (the d3 gate triggers a refresh, then quits immediately,
# and a frozen loop would block on the git call and time out).

package D3Demo;

use base 'PerlTea::App::GitDash';

package main;

unless (caller) {
    my $repo = shift @ARGV || '.';
    PerlTea->new( model => D3Demo->new( repo => $repo ), alt_screen => 1 )->run;
}

1;
