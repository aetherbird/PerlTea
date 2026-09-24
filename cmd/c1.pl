#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;
use PerlTea::App::Slides;

# C1 demo — slide renderer. Reads a Markdown deck given as the first argument,
# splits it on '---' lines, renders each slide with PerlTea::App::Glow, and
# displays the first slide with a counter footer.
#
# Keys:
#   q          quit
#   right      next slide (prepared for C2)
#   left       previous slide (prepared for C2)

package C1Demo;

use base 'PerlTea::App::Slides';

package main;

unless (caller) {
    my $file = shift @ARGV;
    die "usage: c1.pl <deck.md>\n" unless defined $file && length $file;

    PerlTea->new( model => C1Demo->new( path => $file ), alt_screen => 1 )->run;
}

1;
