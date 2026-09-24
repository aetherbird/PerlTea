use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempfile);
use Time::HiRes qw(time);

use PerlTea;
use PerlTea::App::Logexplorer;

# B4 — Scale. Only the visible window renders, so a very large log loads and
# scrolls within a time budget. These tests exercise the shared
# PerlTea::App::Logexplorer module directly; the demo cmd/b4.pl is driven through
# a PTY against a generated 100k-line file by the acceptance harness.
#
# The point of B4 is that render cost is bounded by the VIEWPORT size, not the
# file size. A naive explorer that re-renders all N lines every frame would blow
# the budget on a big file; these assertions fail for such an implementation.

my $N = 100_000;
my ( $fh, $path ) = tempfile( 'b4-scaleXXXX', TMPDIR => 1, UNLINK => 1, SUFFIX => '.log' );
for my $i ( 1 .. $N ) {
    print {$fh} "12:00:00 host app[$i]: event number $i lorem ipsum dolor sit amet\n";
}
close $fh;

# --- load budget -----------------------------------------------------------
my $t0  = time;
my $app = PerlTea::App::Logexplorer->new( path => $path, width => 80, height => 24 );
my $load = time - $t0;

my @all = $app->lines;
is( scalar(@all), $N, "all $N lines loaded" );
cmp_ok( $load, '<', 5.0, sprintf( 'loaded %d lines in %.3fs (< 5s budget)', $N, $load ) );

# --- only the visible window renders ---------------------------------------
# The rendered view must be exactly `height` rows regardless of how many lines
# the file has — that is the structural proof that scrolling cost is bounded.
my $view = $app->view;
is(
    scalar( split /\n/, $view, -1 ),
    24,
    'view is exactly height rows even for a 100k-line file',
);
like( $view, qr/event number 1\b/, 'the top of a huge file shows its first line' );

# --- scrolling stays cheap at any depth ------------------------------------
# Render budget must not depend on scroll position: rendering near the very end
# of 100k lines is just as cheap as at the top.
$app->update( { type => 'key', key => 'G' } );    # jump to bottom
my $bottom = $app->view;
like( $bottom, qr/event number $N\b/, 'G reaches the last line of a huge file' );

my $t1 = time;
for my $i ( 1 .. 2000 ) {
    $app->viewport->scroll_up;
    $app->view;
}
for my $i ( 1 .. 2000 ) {
    $app->viewport->scroll_down;
    $app->view;
}
my $scroll = time - $t1;
cmp_ok( $scroll, '<', 3.0,
    sprintf( '4000 scroll+render ops in %.3fs (< 3s budget)', $scroll ) );

# --- offset stays clamped at scale -----------------------------------------
$app->viewport->goto_bottom;
is( $app->viewport->offset, $N - 24,
    'bottom offset is lines - height (last full window)' );
$app->viewport->scroll_down(1000);
is( $app->viewport->offset, $N - 24,
    'scrolling past the end stays clamped at the last window' );

done_testing;
