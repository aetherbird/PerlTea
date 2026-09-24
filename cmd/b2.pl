#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;
use PerlTea::App::Logexplorer;

# B2 demo — live-tail log explorer. Opens a log file given as the first argument
# and polls for appended lines without requiring input.
#
# Keys:
#   q          quit
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
        live_tail => 1,
    );
    PerlTea->new( model => $app, alt_screen => 1 )->run;
}

1;
