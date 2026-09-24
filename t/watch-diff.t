#!/usr/bin/env perl
# WATCH - unit tests for the diff/highlight computation and helpers.
#
# Why these matter: the watch gate drives the real bin/ptea-watch through a PTY
# and only checks that the command re-runs and that SGR appears. The *meaning* of
# the diff highlight (which lines change, that unchanged output stays plain, that
# a changed value is wrapped as one contiguous run) is proven here deterministically.

use strict;
use warnings;
use Test::More;

use PerlTea::App::Watch;

my $REV = "\e[7m";    # reverse video on
my $OFF = "\e[27m";   # reverse video off

# ── highlight_diff: a changed line is wrapped, an unchanged line is not ───────
{
    my $prev = "alpha\ntick 1\ngamma\n";
    my $cur  = "alpha\ntick 2\ngamma\n";
    my $out  = PerlTea::App::Watch::highlight_diff( $prev, $cur );
    my @lines = split /\n/, $out;

    is( $lines[0], 'alpha', 'unchanged first line stays plain' );
    is( $lines[2], 'gamma', 'unchanged third line stays plain' );
    is( $lines[1], "${REV}tick 2${OFF}", 'changed middle line wrapped in reverse video' );

    # The changed value renders as one contiguous run (no SGR splitting "tick 2").
    like( $out, qr/\Qtick 2\E/, 'changed value appears contiguously' );
    unlike( $lines[0], qr/\e\[/, 'unchanged line carries no SGR' );
}

# ── identical output produces no SGR at all ──────────────────────────────────
{
    my $same = "same line one\nsame line two\n";
    my $out  = PerlTea::App::Watch::highlight_diff( $same, $same );
    unlike( $out, qr/\e\[/, 'identical outputs yield zero SGR' );
    is( $out, "same line one\nsame line two", 'identical outputs returned (trailing newline trimmed)' );
}

# ── a newly added line (no previous counterpart) is highlighted ──────────────
{
    my $prev = "one\n";
    my $cur  = "one\ntwo\n";
    my $out  = PerlTea::App::Watch::highlight_diff( $prev, $cur );
    my @lines = split /\n/, $out;
    is( $lines[0], 'one', 'pre-existing line stays plain' );
    is( $lines[1], "${REV}two${OFF}", 'newly added line highlighted' );
}

# ── highlighting empty/undef previous (first diff against nothing) ───────────
{
    my $out = PerlTea::App::Watch::highlight_diff( undef, "first\n" );
    is( $out, "${REV}first${OFF}", 'diff against undef previous highlights everything' );
}

# ── run_command: captures output and exit code with no shell ─────────────────
{
    my ( $out, $exit ) = PerlTea::App::Watch::run_command( [ $^X, '-e', 'print "hello\n"' ] );
    is( $out,  "hello\n", 'run_command captures stdout' );
    is( $exit, 0,         'run_command reports a zero exit code' );

    my ( undef, $exit2 ) = PerlTea::App::Watch::run_command( [ $^X, '-e', 'exit 3' ] );
    is( $exit2, 3, 'run_command reports a non-zero exit code' );

    my ( $err_out, $exit3 ) = PerlTea::App::Watch::run_command( [ $^X, '-e', 'print STDERR "oops\n"' ] );
    like( $err_out, qr/oops/, 'run_command merges stderr into the captured output' );
    is( $exit3, 0, 'stderr-only command still exits zero' );
}

# ── parse_args: --interval N -- cmd ... ──────────────────────────────────────
{
    my ( $interval, $argv, $err ) =
        PerlTea::App::Watch::parse_args( '--interval', '0.5', '--', 'echo', 'hi' );
    is( $err,      '',     'well-formed args parse with no error' );
    is( $interval, '0.5',  'interval parsed' );
    is_deeply( $argv, [ 'echo', 'hi' ], 'command and args captured after --' );

    my ( $i2, $a2 ) = PerlTea::App::Watch::parse_args( '--interval=2', '--', 'date' );
    is( $i2, '2', '--interval=N form parsed' );
    is_deeply( $a2, ['date'], 'command after --interval= form' );

    my ( undef, $a3 ) = PerlTea::App::Watch::parse_args( 'ls', '-la' );
    is_deeply( $a3, [ 'ls', '-la' ], 'bare command form (no -- separator) captured' );

    my ( undef, undef, $e4 ) = PerlTea::App::Watch::parse_args('--interval', '1');
    ok( $e4, 'missing command is reported as an error' );
}

# ── model: a run_result rotates current into prev so the next view diffs ──────
{
    my $app = PerlTea::App::Watch->new( command => [ 'true' ], interval => 1 );
    ( $app ) = $app->update( { type => 'run_result', output => "tick 1\n", exit => 0 } );
    is( $app->{current}, "tick 1\n", 'first result stored as current' );
    ok( !defined $app->{prev}, 'no previous after first run' );
    my $v1 = $app->view;
    unlike( $v1, qr/\e\[7m/, 'first run renders plainly (nothing to diff)' );
    like( $v1, qr/\Qtick 1\E/, 'first run output visible in view' );

    ( $app ) = $app->update( { type => 'run_result', output => "tick 2\n", exit => 0 } );
    is( $app->{prev}, "tick 1\n", 'previous rotated in on second run' );
    my $v2 = $app->view;
    like( $v2, qr/\e\[7m/, 'second run highlights the changed line' );
    like( $v2, qr/\Qtick 2\E/, 'second run shows new value' );
}

# ── model: q quits ───────────────────────────────────────────────────────────
{
    my $app = PerlTea::App::Watch->new( command => ['true'], interval => 1 );
    my ( $m, $cmd ) = $app->update( { type => 'key', key => 'q' } );
    isa_ok( $m, 'PerlTea::Msg::Quit', 'q produces a quit message' );
}

done_testing;
