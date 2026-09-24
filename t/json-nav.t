use strict;
use warnings;

# json-nav.t -- the unit gate for ptea-json. It exercises the pure JSON loading,
# visible tree rows, path navigation, and bad-filter handling against the tracked
# fixture so the CLI gate is deterministic.

use Test::More;
use PerlTea::App::Json;

my $fixture = 'testdata/json/sample.json';
my ( $data, $err ) = PerlTea::App::Json::load_document($fixture);
is( $err, '', 'fixture JSON loads without an error' );
ok( ref($data) eq 'HASH', 'fixture decoded to a hash root' );

my @rows = PerlTea::App::Json::visible_rows( $data, { '' => 1 } );
my $text = join "\n", map { $_->{text} } @rows;
like( $text, qr/\bmeta\b/, 'top-level meta key is rendered' );
like( $text, qr/\bapps\b/, 'top-level apps key is rendered' );
like( $text, qr/\bcount\b.*8/, 'scalar top-level values render with previews' );

my ( $sentinel, $path_err ) =
    PerlTea::App::Json::node_at_path( $data, [qw(meta sentinel)] );
is( $path_err, '', 'node_at_path reaches nested keys' );
is( $sentinel, 'JSON_NODE_SENTINEL', 'node_at_path reaches the nested sentinel' );

my ( $first_app, undef, $filter_err ) =
    PerlTea::App::Json::filter_path( $data, '.apps[0]' );
is( $filter_err, '', 'filter_path supports array indexes' );
is( $first_app, 'glow', 'filter_path returns an indexed array value' );

my ( $filtered, $filter_path, $sentinel_filter_err ) =
    PerlTea::App::Json::filter_path( $data, '.meta.sentinel' );
is( $sentinel_filter_err, '', 'filter_path accepts dotted paths' );
is_deeply( $filter_path, [qw(meta sentinel)], 'filter_path reports the selected path' );
is( $filtered, 'JSON_NODE_SENTINEL', 'filter_path returns the nested sentinel' );

my ( undef, undef, $bad_err ) =
    PerlTea::App::Json::filter_path( $data, '[[[' );
like( $bad_err, qr/expected/, 'bad filter syntax returns an error instead of dying' );

my $app = PerlTea::App::Json->new( data => $data, width => 80, height => 20 );
like( $app->view, qr/meta/, 'model view includes top-level keys' );

my ($after_bad) = $app->update( { type => 'key', key => '/' } );
$after_bad->update( { type => 'key', key => '[', char => '[' } );
$after_bad->update( { type => 'key', key => '[', char => '[' } );
$after_bad->update( { type => 'key', key => '[', char => '[' } );
$after_bad->update( { type => 'key', key => 'enter' } );
like( $after_bad->view, qr/Filter error:/, 'bad interactive filter is surfaced in the view' );

my $app2 = PerlTea::App::Json->new( data => $data, width => 80, height => 20 );
$app2->update( { type => 'key', key => '/' } );
for my $ch ( split //, '.meta.sentinel' ) {
    $app2->update( { type => 'key', key => $ch, char => $ch } );
}
$app2->update( { type => 'key', key => 'enter' } );
like( $app2->view, qr/JSON_NODE_SENTINEL/,
    'interactive filter renders the nested sentinel' );

my ($q) = $app2->update( { type => 'key', key => 'q' } );
isa_ok( $q, 'PerlTea::Msg::Quit', 'q yields a quit message' );

done_testing;
