use strict;
use warnings;
use Test::More;

# Every module under lib/ must compile. Green from turn one; it grows automatically
# as packages are added.
use File::Find;

my @modules;
find(
    sub { push @modules, $File::Find::name if /\.pm$/ },
    'lib',
);

plan tests => scalar @modules;

for my $file (sort @modules) {
    my $out = qx{$^X -Ilib -c "$file" 2>&1};
    is( $? >> 8, 0, "compiles: $file" ) or diag $out;
}
