#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;
use PerlTea::App::Logexplorer;

# B1 demo — log explorer source + display. Opens a log file given as the first
# argument (falling back to PerlTea::App::Logexplorer's default source when none
# is given), reads its contents, and shows them in a scrollable viewport.
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
    );
    PerlTea->new( model => $app, alt_screen => 1 )->run;
}

1;
