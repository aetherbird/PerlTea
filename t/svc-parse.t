#!/usr/bin/env perl
# SVC - unit tests for the service manager's parser and pure helpers.
#
# Why these matter: the svc gate drives the real bin/ptea-svc through a PTY, but
# the *correctness* of parsing, loading, and action dispatch is proven here
# deterministically, against the tracked fixture under testdata/svc/units.txt.

use strict;
use warnings;
use Test::More;

use PerlTea::App::Svc;

my $fixture = 'testdata/svc/units.txt';

sub slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot open $path: $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

# ── load_units: fixture mode ─────────────────────────────────────────────────
{
    local $ENV{PERLTEA_SYSTEMCTL_FIXTURE} = $fixture;
    my ( $units, $error ) = PerlTea::App::Svc::load_units();
    ok( @$units, 'fixture loads at least one unit' );
    is( $error, '', 'fixture load reports no error' );
}

# ── parse_list_units: shape and field extraction ─────────────────────────────
my $raw   = slurp($fixture);
my $units = PerlTea::App::Svc::parse_list_units($raw);
is( scalar @$units, 4, 'fixture contains four unit rows' );

is( $units->[0]{unit},   'ssh.service',   'first unit name parsed' );
is( $units->[0]{load},   'loaded',        'first unit load state parsed' );
is( $units->[0]{active}, 'active',        'first unit active state parsed' );
is( $units->[0]{sub},    'running',       'first unit sub state parsed' );
like( $units->[0]{description}, qr/OpenSSH/, 'first unit description parsed' );

is( $units->[2]{unit},   'ptea-sentinel.service', 'sentinel unit parsed' );
is( $units->[2]{active}, 'failed',                'sentinel active state is failed' );
is( $units->[2]{sub},    'failed',                'sentinel sub state is failed' );

# ── the model view: renders fixture rows ─────────────────────────────────────
my $app = PerlTea::App::Svc->new( fixture => $fixture, width => 80, height => 12 );
my $view = $app->view;
like( $view, qr/ptea-sentinel\.service/, 'view shows the sentinel unit' );
like( $view, qr/failed/,                  'view shows the failed state' );
like( $view, qr/ssh\.service/,             'view shows the ssh unit' );

# ── selection movement clamps at the ends ────────────────────────────────────
$app->update( { type => 'key', key => 'up' } );
is( $app->{selected}, 0, 'selection does not move above the first row' );
$app->update( { type => 'key', key => 'down' } );
is( $app->{selected}, 1, 'down moves the selection' );
$app->{selected} = 3;
$app->update( { type => 'key', key => 'down' } );
is( $app->{selected}, 3, 'selection does not move below the last row' );

# ── q quits ──────────────────────────────────────────────────────────────────
{
    my $fresh = PerlTea::App::Svc->new( fixture => $fixture );
    my ($m) = $fresh->update( { type => 'key', key => 'q' } );
    isa_ok( $m, 'PerlTea::Msg::Quit', 'q produces a quit message' );
}

# ── action command uses PERLTEA_SYSTEMCTL_CMD and returns action_done ────────
{
    local $ENV{PERLTEA_SYSTEMCTL_CMD} = 'echo';
    my $cmd = PerlTea::App::Svc::action_cmd( 'ptea-sentinel.service', 'start' );
    ok( ref $cmd eq 'CODE', 'action_cmd returns a coderef' );
    my $msg = $cmd->();
    is( $msg->{type},   'action_done',           'action command reports action_done' );
    is( $msg->{unit},   'ptea-sentinel.service', 'action_done preserves the unit' );
    is( $msg->{action}, 'start',                 'action_done preserves the action' );
    ok( $msg->{ok}, 'echo start <unit> exits 0' );
}

# ── log command returns log_result with lines ────────────────────────────────
{
    my $cmd = PerlTea::App::Svc::log_cmd('ptea-sentinel.service');
    ok( ref $cmd eq 'CODE', 'log_cmd returns a coderef' );
    my $msg = $cmd->();
    is( $msg->{type}, 'log_result',            'log command reports log_result' );
    is( $msg->{unit}, 'ptea-sentinel.service', 'log_result preserves the unit' );
    ok( ref $msg->{lines} eq 'ARRAY', 'log_result carries an array of lines' );
}

done_testing();
