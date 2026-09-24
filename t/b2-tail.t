use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin;
use lib "$FindBin::Bin/../lib";

use PerlTea::App::Logexplorer;

# B2 — Live tail. The log explorer's subscription polls file sources for
# appended lines and updates the same viewport used by B1. These tests keep the
# behavior deterministic by triggering the tail_tick message directly.

my ( $fh, $path ) = tempfile( UNLINK => 1 );
print {$fh} "alpha\nbeta\n";
close $fh;

my $app = PerlTea::App::Logexplorer->new(
    path          => $path,
    width         => 40,
    height        => 5,
    live_tail     => 1,
    tail_interval => 0.05,
);

is_deeply( [ $app->lines ], [ 'alpha', 'beta' ], 'initial file contents are loaded' );

my $subs = $app->subscriptions;
is( scalar(@$subs), 1, 'live_tail file source exposes one polling subscription' );
is( $subs->[0]{every}, 0.05, 'subscription uses the configured poll interval' );
is_deeply( $subs->[0]{msg}->(), { type => 'tail_tick' }, 'subscription emits tail_tick messages' );

open my $append, '>>', $path or die "append $path: $!";
print {$append} "gamma\n";
close $append;

$app->update( { type => 'tail_tick' } );
is_deeply( [ $app->lines ], [ 'alpha', 'beta', 'gamma' ], 'tail_tick appends a completed new line' );
like( $app->view, qr/gamma/, 'newly appended line is visible in the viewport' );

open $append, '>>', $path or die "append partial $path: $!";
print {$append} "partial";
close $append;

$app->update( { type => 'tail_tick' } );
is_deeply(
    [ $app->lines ],
    [ 'alpha', 'beta', 'gamma' ],
    'partial trailing line is held until a newline arrives',
);

open $append, '>>', $path or die "complete partial $path: $!";
print {$append} "-done\n";
close $append;

$app->update( { type => 'tail_tick' } );
is_deeply(
    [ $app->lines ],
    [ 'alpha', 'beta', 'gamma', 'partial-done' ],
    'partial line is completed on the next poll',
);

my $static = PerlTea::App::Logexplorer->new( path => $path );
is_deeply( $static->subscriptions, [], 'static B1-style file sources do not subscribe' );

my $command = PerlTea::App::Logexplorer->new(
    command   => [ $^X, '-e', 'print "cmd\\n"' ],
    live_tail => 1,
);
is_deeply( $command->subscriptions, [], 'command sources are not live-tailed' );

done_testing;
