use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use PerlTea::App::Logexplorer;

# B3 — Filter/search. The log explorer supports an interactive regex filter:
# '/' opens a prompt, typed characters edit the pattern, Enter applies it, and
# Esc cancels. Matches are highlighted; invalid regexes surface an error.

my $fixture = "$FindBin::Bin/../testdata/log/sample.log";

my $app = PerlTea::App::Logexplorer->new(
    path   => $fixture,
    width  => 80,
    height => 5,
);

is_deeply(
    [ $app->filtered_lines ],
    [ $app->lines ],
    'without a filter the full log is displayed',
);

# Open the filter prompt.
$app->update( { type => 'key', key => '/', rune => '/' } );
ok( $app->{filter_mode}, '"/" enters filter mode' );
like( $app->view, qr{/\[pattern\]}, 'filter prompt is visible with placeholder' );

# Type a pattern and apply it.
for my $ch ( split //, 'BOOTMARK' ) {
    $app->update( { type => 'key', key => $ch, rune => $ch } );
}
$app->update( { type => 'key', key => 'enter', rune => "\r" } );

ok( !$app->{filter_mode}, 'Enter leaves filter mode' );
is( scalar( @{ $app->filtered_lines } ), 1, 'filter narrows to the matching line' );
like(
    $app->filtered_lines->[0],
    qr/BOOTMARK_SENTINEL/,
    'the matching line contains the sentinel',
);
like(
    $app->view,
    qr/\e\[7mBOOTMARK\e\[27m_SENTINEL/,
    'the filtered view shows the highlighted matching line',
);
like(
    $app->view,
    qr/\e\[7mBOOTMARK\e\[27m/,
    'matches are highlighted with reverse video',
);

# Canceling the filter restores the full view.
$app->update( { type => 'key', key => 'esc', rune => "\e" } );
ok( !$app->{filter_mode}, 'Esc cancels filter mode' );
is_deeply(
    [ $app->filtered_lines ],
    [ $app->lines ],
    'Esc clears the filter and restores all lines',
);

# Invalid regex: should not crash and should surface an error.
$app = PerlTea::App::Logexplorer->new(
    path   => $fixture,
    width  => 80,
    height => 5,
);
$app->update( { type => 'key', key => '/', rune => '/' } );
$app->update( { type => 'key', key => '[', rune => '[' } );
$app->update( { type => 'key', key => 'enter', rune => "\r" } );

ok( !$app->{filter_mode}, 'bad regex exits filter mode' );
like( $app->{filter_error}, qr/invalid regex/, 'invalid regex sets filter_error' );
is_deeply(
    [ $app->filtered_lines ],
    [ $app->lines ],
    'invalid regex leaves the view unchanged',
);

# The error clears on the next keypress, restoring the full-height view.
$app->update( { type => 'key', key => 'q', rune => 'q' } );
is( $app->{filter_error}, '', 'the next keypress clears the error' );

# Filter with a regex that uses alternation.
$app = PerlTea::App::Logexplorer->new(
    path   => $fixture,
    width  => 80,
    height => 5,
);
$app->update( { type => 'key', key => '/', rune => '/' } );
for my $ch ( split //, 'WARN|ERROR' ) {
    $app->update( { type => 'key', key => $ch, rune => $ch } );
}
$app->update( { type => 'key', key => 'enter', rune => "\r" } );

is( scalar( @{ $app->filtered_lines } ), 2, 'regex alternation matches two lines' );
like( $app->filtered_lines->[0], qr/WARN/, 'first match is WARN' );
like( $app->filtered_lines->[1], qr/ERROR/, 'second match is ERROR' );

# Empty pattern (Enter with no input) clears an existing filter.
$app->update( { type => 'key', key => '/', rune => '/' } );
$app->update( { type => 'key', key => 'enter', rune => "\r" } );
is_deeply(
    [ $app->filtered_lines ],
    [ $app->lines ],
    'empty pattern clears the filter',
);

done_testing;
