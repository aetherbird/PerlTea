use strict;
use warnings;

# du-scan.t — the unit gate for ptea-du. It builds a known tree and asserts the
# pure scan/aggregate/sort engine, plus the model's drill-down. Building the tree
# in the test (rather than against the live filesystem) keeps it deterministic.

use Test::More;
use File::Temp qw(tempdir);
use PerlTea::App::Du;

my $dir = tempdir( CLEANUP => 1 );

# Tree:
#   big/        -> data.bin (4096) + sub/more.bin (2048) = 6144 bytes
#   small/      -> note.txt (16)
#   loose.txt   -> 100 bytes
mkdir "$dir/big"      or die "mkdir big: $!";
mkdir "$dir/big/sub"  or die "mkdir big/sub: $!";
mkdir "$dir/small"    or die "mkdir small: $!";
_write_bytes( "$dir/big/data.bin",     4096 );
_write_bytes( "$dir/big/sub/more.bin", 2048 );
_write_bytes( "$dir/small/note.txt",   16 );
_write_bytes( "$dir/loose.txt",        100 );

# --- entry_size aggregates recursively, and counts files directly ---
is( PerlTea::App::Du::entry_size("$dir/big"), 6144,
    'entry_size sums files across nested subdirectories' );
is( PerlTea::App::Du::entry_size("$dir/big/sub"), 2048,
    'entry_size of a leaf subdirectory' );
is( PerlTea::App::Du::entry_size("$dir/small"), 16,
    'entry_size of a small directory' );
is( PerlTea::App::Du::entry_size("$dir/loose.txt"), 100,
    'entry_size of a plain file is its own size' );

# --- scan returns the immediate children, sorted largest-first ---
my $entries = PerlTea::App::Du::scan($dir);
is( scalar(@$entries), 3, 'three top-level entries' );
is( $entries->[0]{name}, 'big',   'largest entry (big) is first' );
is( $entries->[1]{name}, 'loose.txt', 'next largest (loose.txt) is second' );
is( $entries->[2]{name}, 'small', 'smallest entry (small) is last' );
is( $entries->[0]{size}, 6144, 'biggest entry carries the aggregate size' );
ok( $entries->[0]{is_dir}, 'big is flagged as a directory' );
ok( !$entries->[1]{is_dir}, 'loose.txt is flagged as a file' );

# strictly descending by size
ok( $entries->[0]{size} >= $entries->[1]{size}
        && $entries->[1]{size} >= $entries->[2]{size},
    'entries are sorted largest-first' );

# --- format_size is human-readable and binary (1024-based) ---
is( PerlTea::App::Du::format_size(1048576), '1.0M', '1 MiB formats as 1.0M' );
is( PerlTea::App::Du::format_size(1024),    '1.0K', '1 KiB formats as 1.0K' );
is( PerlTea::App::Du::format_size(512),     '512B', 'sub-1K bytes shown plainly' );
is( PerlTea::App::Du::format_size(0),       '0B',   'zero bytes' );

# --- model: largest is selected first; drilling reveals the inner file ---
my $app = PerlTea::App::Du->new( path => $dir, width => 80, height => 24 );
is( $app->{entries}[0]{name}, 'big', 'model lists the largest entry first' );
is( $app->{selected}, 0, 'selection starts on the largest entry' );

my ($after) = $app->update( { type => 'key', key => 'enter' } );
like( $after->view, qr/data\.bin/,
    'drilling into the largest directory reveals its file' );
is( $after->{cwd}, "$dir/big", 'cwd descended into the largest directory' );

# ascend returns to the parent and restores the selection
my ($back) = $after->update( { type => 'key', key => 'u' } );
is( $back->{cwd}, $dir, 'ascending returns to the parent directory' );
is( $back->{selected}, 0, 'selection restored to the largest entry' );

# pressing enter on a file (loose.txt) must not descend
$app->{selected} = 1;    # loose.txt
my ($noop) = $app->update( { type => 'key', key => 'enter' } );
is( $noop->{cwd}, $dir, 'enter on a file does not descend' );

# q quits cleanly
my ($q) = $app->update( { type => 'key', key => 'q' } );
isa_ok( $q, 'PerlTea::Msg::Quit', 'q yields a quit message' );

done_testing;

# Write exactly $n bytes to $path.
sub _write_bytes {
    my ( $path, $n ) = @_;
    open my $fh, '>', $path or die "open $path: $!";
    binmode $fh;
    print {$fh} ( 'x' x $n );
    close $fh;
    return;
}
