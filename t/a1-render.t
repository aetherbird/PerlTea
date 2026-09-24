use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Encode qw(decode);
use PerlTea::App::Glow;

# A1 — glow markdown renderer. Snapshot the styled output of a known Markdown
# file against a tracked golden. The gate mutation-checks the golden, so an
# empty/keyword test cannot pass: the test must really read and diff the file.
#
# Force truecolor so the styled headings/code blocks are deterministic
# regardless of the runner's TERM — the golden was generated under this setting.
local $ENV{COLORTERM} = 'truecolor';
delete $ENV{PERLTEA_FORCE_COLORS};

# Read the input fixture (the same file cmd/a1.pl opens).
my $md_path = "$FindBin::Bin/../testdata/glow/sample.md";
open my $mh, '<:encoding(UTF-8)', $md_path or die "cannot open $md_path: $!";
local $/;
my $markdown = <$mh>;
close $mh;

# Render exactly as the demo does (cmd/a1.pl passes width => 80), so the golden
# and the live demo can never drift.
my $rendered = PerlTea::App::Glow::render( $markdown, width => 80 );

# Read the UTF-8 golden into a wide-character string for comparison.
my $golden_path = "$FindBin::Bin/../testdata/a1/sample.golden";
open my $gh, '<:raw', $golden_path or die "cannot open $golden_path: $!";
my $golden = decode( 'UTF-8', <$gh> );
close $gh;

is( $rendered, $golden, 'rendered markdown matches tracked golden' );

# Structural guarantees independent of the golden bytes — these localize a
# regression that a single big snapshot diff might obscure.

like( $rendered, qr/\e\[[0-9;]*m/, 'output contains ANSI SGR (real styling)' );

# The H1 text survives verbatim (the gate also greps for it).
like( $rendered, qr/PerlTea/, 'heading text preserved' );

# Heading is colored/bold via PerlTea::Style (the G4 layer): bold + truecolor fg.
like( $rendered, qr/\e\[1;4;38;2;215;135;255mPerlTea\e\[0m/,
    'H1 rendered through PerlTea::Style with bold + truecolor color' );

# Inline bold uses an attribute on/off pair that does not clobber surroundings.
like( $rendered, qr/\e\[1mterminal UI\e\[22m/, 'inline bold span styled' );

# Inline code is reverse-video and leaves the literal token untouched.
like( $rendered, qr/\e\[7mtea\.NewProgram\(m\)\e\[27m/, 'inline code styled' );

# List bullets are rendered as a bullet glyph, not the raw '-' marker.
like( $rendered, qr/\x{2022} model \/ update \/ view/, 'bullet list item rendered' );

# Fenced code block lines get a background fill via PerlTea::Style.
like( $rendered, qr/\e\[38;2;215;215;175;48;2;38;38;38m.*func main/,
    'fenced code block styled with foreground + background' );

# Inline italic.
like( $rendered, qr/\e\[3mall\e\[23m/, 'inline italic span styled' );

# A few direct unit checks of the renderer's building blocks.
{
    my $h = PerlTea::App::Glow::render('## Hello');
    like( $h, qr/Hello/, 'h2 keeps its text' );
    like( $h, qr/\e\[/,  'h2 is styled' );

    my $r = PerlTea::App::Glow::render( "a\n\nb" );
    is( ( () = $r =~ /\n/g ), 2, 'blank line between paragraphs preserved' );

    # A link renders as underlined text without the URL.
    my $link = PerlTea::App::Glow::render('see [docs](http://x)');
    like( $link, qr/\e\[4mdocs\e\[24m/, 'link text underlined' );
    unlike( $link, qr/http:/, 'link URL dropped from rendered text' );

    # Ordered list.
    my $ol = PerlTea::App::Glow::render('1. first');
    like( $ol, qr/1\. first/, 'ordered list item keeps its number' );

    # Horizontal rule width honours the width option.
    my $hr = PerlTea::App::Glow::render( "---", width => 10 );
    is( ( () = $hr =~ /\x{2500}/g ), 10, 'horizontal rule respects width' );
}

done_testing;
