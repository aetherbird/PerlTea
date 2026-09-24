#!/usr/bin/env perl
# REX — unit tests for the regex playground's match engine.
#
# Why these matter: the rex gate drives the real bin/ptea-rex through a PTY, but
# the *correctness* of the match engine (spans + named captures + graceful
# handling of an invalid pattern) is proven here, deterministically, against a
# known subject line — independent of any terminal behaviour.

use strict;
use warnings;
use Test::More;

use PerlTea::App::Rex;

# ── compile_pattern: valid vs. invalid ──────────────────────────────────────
my ( $re, $err ) = PerlTea::App::Rex::compile_pattern('(?<id>ORD-\d+)');
ok( defined $re, 'a valid pattern compiles to a regex' );
is( $err, undef, 'no error message for a valid pattern' );

my ( $bad, $berr ) = PerlTea::App::Rex::compile_pattern('(');
ok( !defined $bad, 'an unbalanced "(" does not compile' );
ok( defined $berr && length $berr, 'an invalid pattern yields an error message' );
unlike( $berr, qr/ at .* line \d+/, 'the error message is cleaned of file/line noise' );

my ( $empty_re, $empty_err ) = PerlTea::App::Rex::compile_pattern('');
is( $empty_re,  undef, 'an empty pattern compiles to no regex' );
is( $empty_err, undef, 'an empty pattern is not an error' );

# ── find_matches: spans + named captures ────────────────────────────────────
my $line = 'Order IDs: ORD-0001, ORD-0042, ORD-1234.';
my @m = PerlTea::App::Rex::find_matches( $re, $line );
is( scalar @m, 3, 'three ORD matches on the line' );

is( $m[0]{text}, 'ORD-0001', 'first match text' );
is( $m[1]{text}, 'ORD-0042', 'second match text' );
is( $m[2]{text}, 'ORD-1234', 'third match text' );

# Spans must index back to the exact matched substring.
is(
    substr( $line, $m[1]{start}, $m[1]{end} - $m[1]{start} ),
    'ORD-0042',
    'the second match span indexes back to ORD-0042'
);
cmp_ok( $m[0]{end}, '<=', $m[1]{start}, 'matches are non-overlapping and ordered' );

# Named captures are per-match.
is( $m[0]{captures}{id}, 'ORD-0001', 'named capture id for the first match' );
is( $m[1]{captures}{id}, 'ORD-0042', 'named capture id for the second match' );

# A non-matching line yields nothing.
my @none = PerlTea::App::Rex::find_matches( $re, 'no orders here' );
is( scalar @none, 0, 'no matches on a non-matching line' );

# A pattern that can match empty must not loop forever / must report no spans.
my ( $star ) = PerlTea::App::Rex::compile_pattern('\d*');
my @z = PerlTea::App::Rex::find_matches( $star, 'abc 123' );
is( scalar @z, 0, 'a zero-width-capable pattern yields no spans (no infinite loop)' );

# ── highlight_line: each match wrapped in reverse-video SGR ──────────────────
my $hl = PerlTea::App::Rex::highlight_line( $re, $line );
like( $hl, qr/\e\[7mORD-0042\e\[27m/, 'a match is wrapped in reverse video, text intact' );
my $spans = () = $hl =~ /\e\[7m/g;
is( $spans, 3, 'all three matches are highlighted' );
unlike(
    PerlTea::App::Rex::highlight_line( undef, $line ),
    qr/\e\[/,
    'no regex means no highlighting'
);

# ── the model view: highlights + safe handling of an invalid pattern ─────────
my $app = PerlTea::App::Rex->new( lines => [$line], width => 80, height => 24 );
$app->set_pattern('(?<id>ORD-\d+)');
my $v = $app->view;
like( $v, qr/\e\[7mORD-0042\e\[27m/, 'the view highlights the matched order id' );
like( $v, qr/ORD-0042/,              'the view shows the matched text' );
like( $v, qr/id=ORD-0001/,           'the status line shows the first named capture' );

$app->set_pattern('(');
my $v2 = eval { $app->view };
ok( defined $v2, 'the view still renders with an invalid pattern (no crash)' );
like( $v2, qr/Error/, 'the view surfaces an error for an invalid pattern' );
unlike( $v2, qr/\e\[7m/, 'no matches are highlighted while the pattern is invalid' );

done_testing();
