use strict;
use warnings;

# files-list.t — the unit gate for ptea-files. It builds a known tree and asserts
# the pure directory-listing/preview engine plus the model's navigation. Building
# the tree in the test keeps it deterministic and independent of the host filesystem.

use Test::More;
use File::Temp qw(tempdir);
use PerlTea::App::Files;

my $dir = tempdir( CLEANUP => 1 );

# Tree:
#   readme.md       -> markdown with FILEPREVIEW_SENTINEL
#   sub/            -> inner.txt
#   z-note.txt      -> plain text
mkdir "$dir/sub" or die "mkdir sub: $!";
_write_file( "$dir/readme.md", "# Preview Heading\n\nFILEPREVIEW_SENTINEL body text.\n" );
_write_file( "$dir/sub/inner.txt", "inner\n" );
_write_file( "$dir/z-note.txt", "zzz\n" );

# --- list_dir: directories first, then files, all alphabetical ---
my $entries = PerlTea::App::Files::list_dir($dir);
is( scalar(@$entries), 3, 'three entries in test tree' );
is( $entries->[0]{name}, 'sub',      'directory sorts first' );
ok( $entries->[0]{is_dir}, 'sub is flagged as a directory' );
is( $entries->[1]{name}, 'readme.md', 'readme.md follows the directory' );
ok( !$entries->[1]{is_dir}, 'readme.md is flagged as a file' );
is( $entries->[2]{name}, 'z-note.txt', 'files sorted alphabetically' );

# --- preview_for renders markdown via Glow ---
my $md_preview = PerlTea::App::Files::preview_for( "$dir/readme.md", 40 );
like( $md_preview, qr/Preview Heading/, 'markdown preview renders the heading' );
like( $md_preview, qr/FILEPREVIEW_SENTINEL/, 'markdown preview contains the sentinel' );

# --- preview_for renders plain text ---
my $txt_preview = PerlTea::App::Files::preview_for( "$dir/z-note.txt", 40 );
like( $txt_preview, qr/zzz/, 'plain text preview contains its content' );

# --- preview_for renders a directory message ---
my $dir_preview = PerlTea::App::Files::preview_for( "$dir/sub", 40 );
like( $dir_preview, qr/directory/, 'directory preview shows a directory message' );
like( $dir_preview, qr/1 entry/, 'directory preview counts one entry' );

# --- model starts on the first entry (a directory) ---
my $app = PerlTea::App::Files->new( path => $dir, width => 120, height => 30 );
is( $app->{entries}[0]{name}, 'sub', 'model selects the first directory' );
like( $app->view, qr/sub\//, 'initial view lists the directory' );

# --- moving down lands on the markdown file and updates the preview ---
my ($after) = $app->update( { type => 'key', key => 'down' } );
is( $after->{selected}, 1, 'selection moved down' );
is( $after->{entries}[1]{name}, 'readme.md', 'second entry is the markdown file' );
like( $after->view, qr/FILEPREVIEW_SENTINEL/, 'preview pane shows the markdown body' );

# --- Tab switches focus ---
my ($tab) = $after->update( { type => 'key', key => 'tab' } );
is( $tab->{focus}, 'preview', 'tab switches focus to preview' );

# --- preview focus scrolls ---
my ($scroll) = $tab->update( { type => 'key', key => 'down' } );
is( $scroll->{preview_offset}, 1, 'down scrolls the preview when focused' );

# --- enter descends into the selected directory ---
my $app2 = PerlTea::App::Files->new( path => $dir, width => 120, height => 30 );
my ($descend) = $app2->update( { type => 'key', key => 'enter' } );
is( $descend->{path}, "$dir/sub", 'enter descends into the selected directory' );
like( $descend->view, qr/inner\.txt/, 'descended view shows the inner file' );

# --- left returns to the parent ---
my ($up) = $descend->update( { type => 'key', key => 'left' } );
is( $up->{path}, $dir, 'left returns to the parent directory' );

# --- q quits cleanly ---
my ($q) = $app->update( { type => 'key', key => 'q' } );
isa_ok( $q, 'PerlTea::Msg::Quit', 'q yields a quit message' );

done_testing;

sub _write_file {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} $text;
    close $fh;
    return;
}
