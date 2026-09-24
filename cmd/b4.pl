#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;
use PerlTea::App::Logexplorer;

# B4 demo — log explorer at scale. Opens a log file given as the first argument
# (falling back to PerlTea::App::Logexplorer's default source when none is
# given). Only the visible window of the log is ever rendered, so even a very
# large file (100k+ lines) loads and scrolls within the frame budget.
#
# Keys:
#   q          quit
#   /          open filter prompt
#   up/k       scroll up one line
#   down/j     scroll down one line
#   pgup       scroll up one page
#   pgdown     scroll down one page
#   g/home     jump to top
#   G/end      jump to bottom

unless (caller) {
    my $file = shift @ARGV;
    my $app  = PerlTea::App::Logexplorer->new(
        ( defined $file && length $file ? ( path => $file ) : () ),
    );
    PerlTea->new( model => $app, alt_screen => 1 )->run;
}

1;
