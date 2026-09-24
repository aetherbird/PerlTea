#!/usr/bin/env perl
# CPAN - unit tests for MetaCPAN fixture parsing and offline search.
#
# Why these matter: the PTY gate proves the installed command renders fixture
# results, while this test proves the parser maps the MetaCPAN _search shape into
# stable module rows and reports bad JSON without crashing.

use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);

use PerlTea::App::CPAN;

my $fixture = 'testdata/cpan/search.json';
my $json = PerlTea::App::CPAN::read_fixture($fixture);
ok( length $json, 'fixture JSON is readable' );

my $data = JSON::PP->new->utf8->decode($json);
my @results = PerlTea::App::CPAN::parse_search_response($data);
is( scalar @results, 3, 'three fixture hits parse into three results' );
is( $results[0]{name}, 'Mojolicious', 'module name comes from module array' );
is( $results[0]{abstract}, 'Real-time web framework', 'abstract is preserved' );
is( $results[0]{author}, 'SRI', 'author is preserved' );
is( $results[0]{version}, '9.99', 'version is preserved' );
is( $results[1]{distribution}, 'Dancer2', 'distribution is preserved' );

my ( $offline, $err ) = PerlTea::App::CPAN::search( 'web', fixture => $fixture );
is( $err, undef, 'offline fixture search does not error' );
is( scalar @$offline, 3, 'offline fixture search returns all fixture rows' );
is( $offline->[0]{name}, 'Mojolicious', 'offline search returns Mojolicious' );

my ( $missing, $missing_err ) = PerlTea::App::CPAN::search( 'web', fixture => 'testdata/cpan/missing.json' );
is_deeply( $missing, [], 'a missing fixture returns an empty result list' );
like( $missing_err, qr/cannot open/, 'a missing fixture returns a readable error' );

my $app = PerlTea::App::CPAN->new( fixture => $fixture, width => 80, height => 12 );
$app->{results} = $offline;
$app->{status} = '3 result(s) for "web".';
my $view = $app->view;
like( $view, qr/Mojolicious/, 'view renders the module name' );
like( $view, qr/Real-time web framework/, 'view renders the abstract' );

my ( $bad, $bad_err ) = do {
    my $tmp = File::Spec->catfile( tempdir( CLEANUP => 1 ), 'bad-search.json' );
    open my $fh, '>:encoding(UTF-8)', $tmp or die "cannot write $tmp: $!";
    print {$fh} '{';
    close $fh;
    my @ret = PerlTea::App::CPAN::search( 'web', fixture => $tmp );
    @ret;
};
is_deeply( $bad, [], 'bad JSON returns an empty result list' );
ok( defined $bad_err && length $bad_err, 'bad JSON returns an error string' );

done_testing();
