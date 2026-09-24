use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use PerlTea::App::GitDash;

# D1 — log parsing. The fixture is the tab-separated format produced by
# GitDash::git_commands, so commit subjects can contain spaces without ambiguity.

my $fixture = "$FindBin::Bin/../testdata/git/log.txt";
open my $fh, '<', $fixture or die "$fixture: $!";
local $/;
my $text = <$fh>;
close $fh;

my $commits = PerlTea::App::GitDash::parse_log($text);
is( scalar(@$commits), 3, 'all log entries parsed' );

is(
    $commits->[0]{hash},
    '4f3c2a1b5d6e7f8091a2b3c4d5e6f708192a3b4c',
    'full hash parsed',
);
is( $commits->[0]{short}, '4f3c2a1', 'short hash parsed' );
is( $commits->[0]{author}, 'Scout', 'author parsed' );
is( $commits->[0]{date}, '2026-06-13', 'date parsed' );
is( $commits->[0]{subject}, 'Implement C2 slides polish', 'subject parsed' );
is_deeply( $commits->[0]{refs}, [ 'main', 'origin/main' ], 'HEAD decoration normalized' );

is_deeply(
    $commits->[1]{refs},
    [ 'tag: v0.1.0', 'feature/git-dash' ],
    'multiple refs parsed',
);
is_deeply( $commits->[2]{refs}, [], 'empty refs become an empty arrayref' );

my $commands = PerlTea::App::GitDash::git_commands('/tmp/repo');
is( $commands->{status}[0], 'git', 'git command vectors start with git' );
is( $commands->{status}[2], '/tmp/repo', 'git command vectors include repo path' );
like(
    join( ' ', @{ $commands->{log} } ),
    qr/pretty=format:%H%x09%h%x09%an%x09%ad%x09%D%x09%s/,
    'log command uses the parser fixture format',
);

done_testing;
