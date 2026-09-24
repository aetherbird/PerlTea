use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

# C1 — slide deck splitter. Verify that the shared slide app splits the tracked
# fixture into the expected number of slides and that each slide retains its
# heading.
use PerlTea::App::Slides;

my $deck_path = "$FindBin::Bin/../testdata/slides/deck.md";
open my $fh, '<:encoding(UTF-8)', $deck_path or die "cannot open $deck_path: $!";
local $/;
my $markdown = <$fh>;
close $fh;

my $slides = PerlTea::App::Slides::split_deck($markdown);

is( scalar(@$slides), 4, 'deck.md splits into exactly 4 slides' );

like( $slides->[0], qr/^# Slide One/,  'slide 1 has the expected heading' );
like( $slides->[1], qr/^# Slide Two/,  'slide 2 has the expected heading' );
like( $slides->[2], qr/^# Slide Three/, 'slide 3 has the expected heading' );
like( $slides->[3], qr/^# Slide Four/, 'slide 4 has the expected heading' );

# Slides should not contain the delimiter.
for my $i ( 0 .. $#$slides ) {
    unlike( $slides->[$i], qr/^---\s*$/m,
        "slide $i does not contain a delimiter line" );
}

# Rendering a single slide produces non-empty styled text.
my $rendered = PerlTea::App::Slides::render_slide( $slides->[0], width => 80 );
ok( length($rendered) > 0, 'render_slide returns content' );
like( $rendered, qr/Slide One/, 'rendered slide contains the title' );

# The model loads the deck and reports the correct total.
my $model = PerlTea::App::Slides->new( path => $deck_path, width => 80, height => 24 );
is( $model->total, 4, 'model total is 4 slides' );
is( $model->current, 0, 'model starts on slide 0' );

# The view contains the current slide content and the counter footer.
my $view = $model->view;
like( $view, qr/Slide One/, 'view shows the first slide title' );
like( $view, qr/1\/4/, 'view contains the 1/4 counter' );

# View dimensions match the requested terminal size.
my @rows = split /\n/, $view;
is( scalar(@rows), 24, 'view has exactly 24 rows' );

# q returns the canonical quit sentinel.
my ( $next, $cmd ) = $model->update( { type => 'key', key => 'q' } );
ok( $next->isa('PerlTea::Msg::Quit'), 'q returns the quit sentinel' );

done_testing;
