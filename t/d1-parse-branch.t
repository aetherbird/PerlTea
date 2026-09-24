use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use PerlTea::App::GitDash;

# D1 — branch parsing. The fixture is captured `git branch --list --no-color -vv`
# style output, including tracking state, gone upstreams, and remote branches.

my $fixture = "$FindBin::Bin/../testdata/git/branches.txt";
open my $fh, '<', $fixture or die "$fixture: $!";
local $/;
my $text = <$fh>;
close $fh;

my $branches = PerlTea::App::GitDash::parse_branches($text);
is( scalar(@$branches), 4, 'all fixture branches parsed' );

is( $branches->[0]{name}, 'main', 'current branch name parsed' );
ok( $branches->[0]{current}, 'current branch marker preserved' );
is( $branches->[0]{sha}, '4f3c2a1', 'branch sha parsed' );
is( $branches->[0]{upstream}, 'origin/main', 'upstream parsed' );
is( $branches->[0]{ahead}, 1, 'ahead count parsed' );
is( $branches->[0]{behind}, 2, 'behind count parsed' );
is( $branches->[0]{subject}, 'Implement C2 slides polish', 'subject parsed' );

ok( !$branches->[1]{current}, 'non-current branch is not marked current' );
is( $branches->[1]{upstream}, 'origin/feature/git-dash', 'upstream without state parsed' );
is( $branches->[1]{ahead}, 0, 'missing ahead defaults to zero' );

ok( $branches->[2]{gone}, 'gone upstream state parsed' );
is( $branches->[2]{upstream}, 'origin/stale/local', 'gone branch still keeps upstream name' );

ok( $branches->[3]{remote}, 'remote branch detected by remotes/ prefix' );

done_testing;
