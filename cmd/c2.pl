#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;
use PerlTea::App::Slides;

# C2 demo — slides navigate + polish. Reads a Markdown deck given as the first
# argument, splits it on '---' lines, renders each slide with PerlTea::App::Glow
# (fenced code blocks are highlighted by the renderer), and presents one
# centered slide at a time with a centered "n/Total" counter footer.
#
# Navigation clamps at both ends, so the counter never underflows to 0/N or
# overflows past N/N.
#
# Keys:
#   right / l / n / space   next slide
#   left  / h / p           previous slide
#   q                       quit

package C2Demo;

use base 'PerlTea::App::Slides';

package main;

unless (caller) {
    my $file = shift @ARGV;
    die "usage: c2.pl <deck.md>\n" unless defined $file && length $file;

    PerlTea->new( model => C2Demo->new( path => $file ), alt_screen => 1 )->run;
}

1;
