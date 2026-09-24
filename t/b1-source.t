use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use PerlTea;
use PerlTea::App::Logexplorer;

# B1 — Source + display. The log explorer reads a log source and shows its
# current contents in a scrollable viewport. These tests exercise the shared
# PerlTea::App::Logexplorer module directly (the demo cmd/b1.pl is a thin wrapper
# driven separately by the PTY acceptance harness).

my $fixture = "$FindBin::Bin/../testdata/log/sample.log";
ok( -r $fixture, "fixture log $fixture is readable" );

# --- loading a file source -------------------------------------------------
my $app = PerlTea::App::Logexplorer->new(
    path => $fixture, width => 80, height => 24,
);

my @lines = $app->lines;
is( scalar(@lines), 7, 'all 7 fixture lines loaded' );
like( $lines[1], qr/BOOTMARK_SENTINEL/, 'sentinel line present in loaded lines' );

# The whole fixture fits on screen, so the rendered view must show the sentinel
# (this is exactly what gate b1 asserts via the PTY).
my $view = $app->view;
like( $view, qr/BOOTMARK_SENTINEL/, 'rendered view displays the fixture contents' );
is(
    scalar( split /\n/, $view, -1 ),
    24,
    'view is exactly height rows (viewport fixed size)',
);

# --- navigation + quit -----------------------------------------------------
my ( $m, $cmd ) = $app->update( { type => 'key', key => 'down' } );
is( $app->viewport->offset, 0, 'short log cannot scroll past the end (clamped)' );

# A taller-than-fits scenario: shrink the viewport so scrolling has room.
$app->update( { type => 'resize', width => 80, height => 3 } );
is( $app->viewport->offset, 0, 'after resize the offset starts at the top' );
$app->update( { type => 'key', key => 'down' } );
is( $app->viewport->offset, 1, 'down scrolls one line when content overflows' );
$app->update( { type => 'key', key => 'G' } );
is( $app->viewport->offset, 4, 'G jumps to the last possible offset (7 lines / 3 rows)' );
$app->update( { type => 'key', key => 'g' } );
is( $app->viewport->offset, 0, 'g jumps back to the top' );

( $m, $cmd ) = $app->update( { type => 'key', key => 'q' } );
isa_ok( $m, 'PerlTea::Msg::Quit', 'q returns a quit message' );

# --- a missing source does not die -----------------------------------------
my $missing = PerlTea::App::Logexplorer->new(
    path => "$FindBin::Bin/../testdata/log/does-not-exist.log",
);
like(
    join( "\n", $missing->lines ),
    qr/cannot open/,
    'an unreadable source surfaces a diagnostic line instead of dying',
);

# --- default source selection ----------------------------------------------
# When no candidate is readable, default_source falls back to the given fixture.
my $src = PerlTea::App::Logexplorer::default_source(
    candidates => ['/no/such/log/at/all'],
    fixture    => $fixture,
);
is( $src->{type}, 'file', 'default_source returns a file descriptor on fallback' );
is( $src->{path}, $fixture, 'default_source falls back to the fixture' );

# A readable candidate is preferred over the fixture.
my $src2 = PerlTea::App::Logexplorer::default_source(
    candidates => [ '/no/such/log', $fixture ],
    fixture    => '/some/other/place',
);
is( $src2->{path}, $fixture, 'default_source picks the first readable candidate' );

# default_source with no overrides always yields a usable descriptor.
my $src3 = PerlTea::App::Logexplorer::default_source();
ok( $src3->{type} eq 'file' || $src3->{type} eq 'command',
    'default_source always returns a file or command descriptor' );

done_testing;
