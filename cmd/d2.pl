#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;
use PerlTea::App::GitDash;

# D2 demo — git dashboard layout + focus. Renders a multi-pane dashboard for the
# current repo (or a path given as the first argument). Tab cycles focus between
# the Branches, Status, and Log panes; q quits. The panes reflow when the
# terminal is resized.

package D2Demo;

use base 'PerlTea::App::GitDash';

package main;

unless (caller) {
    my $repo = shift @ARGV || '.';
    PerlTea->new( model => D2Demo->new( repo => $repo ), alt_screen => 1 )->run;
}

1;
