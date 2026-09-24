#!/usr/bin/env perl
# TOP - unit tests for the process viewer's parser and pure helpers.
#
# Why these matter: the top gate drives the real bin/ptea-top through a PTY,
# but the *correctness* of parsing, sorting, and filtering is proven here,
# deterministically, against the tracked fixture under testdata/top/ps.txt.

use strict;
use warnings;
use Test::More;

use PerlTea::App::Top;

my $fixture = 'testdata/top/ps.txt';

sub slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot open $path: $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

# ── load_processes: fixture mode ──────────────────────────────────────────────
{
    local $ENV{PERLTEA_PS_FIXTURE} = $fixture;
    my ( $procs, $error ) = PerlTea::App::Top::load_processes();
    ok( @$procs, 'fixture loads at least one process' );
    is( $error, '', 'fixture load reports no error' );
}

# ── parse_ps_text: shape and numeric conversion ───────────────────────────────
my $raw = slurp($fixture);
my $procs = PerlTea::App::Top::parse_ps_text($raw);
is( scalar @$procs, 4, 'fixture contains four process rows' );

is( $procs->[0]{user},    'scout',      'first process user parsed' );
is( $procs->[0]{pid},     1001,         'first process pid is numeric' );
is( $procs->[0]{command}, 'perl ptea-sentinel-proc', 'command field preserved' );
cmp_ok( $procs->[0]{cpu}, '==', 12.5, 'CPU parsed as a number' );
cmp_ok( $procs->[0]{mem}, '==', 3.2,  'MEM parsed as a number' );

# ── sort_processes: by CPU descending, PID tie-breaker ────────────────────────
my $sorted = PerlTea::App::Top::sort_processes($procs);
is( $sorted->[0]{command}, 'stress-cpu-hog', 'highest-CPU process sorts first' );
is( $sorted->[1]{command}, 'perl ptea-sentinel-proc', 'second by CPU' );

# ── filter_processes: command, user, and PID matching ─────────────────────────
my $sentinel = PerlTea::App::Top::filter_processes( $procs, 'sentinel' );
is( scalar @$sentinel, 1, 'filter narrows to the sentinel process' );
is( $sentinel->[0]{command}, 'perl ptea-sentinel-proc', 'sentinel match is by command' );

my $root = PerlTea::App::Top::filter_processes( $procs, 'root' );
is( scalar @$root, 1, 'filter narrows by user' );

my $pid = PerlTea::App::Top::filter_processes( $procs, '1002' );
is( scalar @$pid, 1, 'filter narrows by PID' );

my $all = PerlTea::App::Top::filter_processes( $procs, '' );
is( scalar @$all, 4, 'empty filter returns all processes' );

# ── the model view: renders fixture rows and respects a filter ────────────────
my $app = PerlTea::App::Top->new( fixture => $fixture, width => 80, height => 12 );
my $view = $app->view;
like( $view, qr/ptea-sentinel-proc/, 'view shows the sentinel process' );
like( $view, qr/stress-cpu-hog/,     'view shows the high-CPU process' );

$app->update( { type => 'key', key => '/' } );
for my $ch ( split //, 'sentinel' ) {
    $app->update( { type => 'key', key => $ch, rune => $ch } );
}
$app->update( { type => 'key', key => 'enter' } );
my $filtered_view = $app->view;
like( $filtered_view, qr/ptea-sentinel-proc/, 'filtered view keeps the matching process' );
unlike( $filtered_view, qr/stress-cpu-hog/,   'filtered view drops non-matching processes' );

# ── kill command uses PERLTEA_KILL_CMD and returns a kill_done message ────────
{
    local $ENV{PERLTEA_KILL_CMD} = 'echo';
    my $cmd = PerlTea::App::Top::kill_cmd(12345);
    ok( ref $cmd eq 'CODE', 'kill_cmd returns a coderef' );
    my $msg = $cmd->();
    is( $msg->{type}, 'kill_done', 'kill command reports kill_done' );
    is( $msg->{pid},  12345,       'kill_done preserves the pid' );
    ok( $msg->{ok}, 'echo "12345" exits 0' );
}

done_testing();
