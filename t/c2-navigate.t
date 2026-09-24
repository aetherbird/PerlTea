use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

# C2 — slide navigation + polish. The slide counter must track navigation and
# CLAMP at both ends: prev at the first slide stays 1/N (no 0/N underflow); next
# past the last slide stays N/N (no N+1/N overflow). Also verifies the presenter
# key aliases and that the centered counter footer matches the current slide.
use PerlTea::App::Slides;

my $deck_path = "$FindBin::Bin/../testdata/slides/deck.md";

sub press {
    my ( $model, $key ) = @_;
    my ($next) = $model->update( { type => 'key', key => $key, rune => $key } );
    return $next;
}

# Counter visible in the rendered view, e.g. "2/4".
sub counter_in_view {
    my ($model) = @_;
    my $view = $model->view;
    return ($view =~ m{(\d+/\d+)}) ? $1 : '';
}

my $model = PerlTea::App::Slides->new( path => $deck_path, width => 80, height => 24 );
is( $model->total, 4, 'deck has 4 slides' );
is( $model->current, 0, 'starts on slide 0 (1/4)' );
is( counter_in_view($model), '1/4', 'view counter starts at 1/4' );

# Underflow guard: prev at the first slide stays put.
press( $model, 'left' );
is( $model->current, 0, 'prev at slide 1 clamps (no underflow)' );
is( counter_in_view($model), '1/4', 'counter stays 1/4 after prev at start' );
unlike( $model->view, qr{0/4}, 'view never shows 0/4' );

# Arrow forward navigation, counter follows.
press( $model, 'right' );
is( $model->current, 1, 'right advances to slide 2' );
is( counter_in_view($model), '2/4', 'counter is 2/4' );

# vi-style and presenter aliases.
press( $model, 'l' );
is( $model->current, 2, "'l' advances to slide 3" );
press( $model, 'n' );
is( $model->current, 3, "'n' advances to slide 4" );
press( $model, 'h' );
is( $model->current, 2, "'h' rewinds to slide 3" );
press( $model, 'p' );
is( $model->current, 1, "'p' rewinds to slide 2" );

# Space advances.
press( $model, 'space' );
is( $model->current, 2, 'space advances a slide' );

# Overflow guard: many nexts past the end clamp at the last slide.
press( $model, 'right' ) for 1 .. 10;
is( $model->current, 3, 'next past the end clamps at the last slide' );
is( counter_in_view($model), '4/4', 'counter clamps at 4/4' );
unlike( $model->view, qr{5/4}, 'view never shows 5/4' );

# The counter matches the current slide after navigation back.
press( $model, 'left' );
is( counter_in_view($model), '3/4', 'counter matches current slide after prev' );

# View is exactly width x height (centered layout preserves dimensions).
my @rows = split /\n/, $model->view, -1;
is( scalar(@rows), 24, 'view has exactly 24 rows' );
is( length($rows[0]), 80, 'each row is exactly 80 columns' );

# Fenced code from slide 3 is rendered (code highlighting via glow).
my $m3 = PerlTea::App::Slides->new( path => $deck_path, width => 80, height => 24 );
press( $m3, 'right' ) for 1 .. 2;    # to slide 3 (the ```go block)
like( $m3->view, qr/Println/, 'code-block content is rendered on slide 3' );

# q quits.
my ($q) = $m3->update( { type => 'key', key => 'q' } );
ok( $q->isa('PerlTea::Msg::Quit'), 'q returns the quit sentinel' );

done_testing;
