#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;
use PerlTea::App::Logexplorer;

# B3 demo — log explorer filter/search. Opens a log file given as the first
# argument (falling back to PerlTea::App::Logexplorer's default source when none
# is given), then type '/' to open the filter prompt, enter a regex, and press
# Enter to narrow the view. Matches are highlighted. An invalid regex is shown
# as an error instead of crashing.
#
# Keys:
#   q          quit
#   /          open filter prompt
#   Enter      apply the filter pattern
#   Esc        cancel the filter prompt
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
