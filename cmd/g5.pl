#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;
use PerlTea::Style;
use PerlTea::Layout;

# G5 demo — layout. A header/body/footer composed with PerlTea::Layout that
# reflows at any terminal size. There are deliberately NO absolute screen
# coordinates anywhere: the header and footer are fixed-height, the body flexes
# to fill whatever is left, and everything stretches to the current width. Resize
# the terminal and the whole thing re-lays-out from the same code.
#
# G5Demo::view_for is a pure function of (width, height, frame) so the snapshot
# test (t/g5-layout.t) can render the exact same layout the demo draws, keeping
# the goldens drift-free.

package G5Demo;

sub new { return bless { w => 80, h => 24, count => 0 }, shift }

sub init { return undef }

sub update {
    my ( $self, $msg ) = @_;
    if ( $msg->{type} && $msg->{type} eq 'resize' ) {
        $self->{w} = $msg->{width};
        $self->{h} = $msg->{height};
        return ( $self, undef );
    }
    return ( PerlTea->quit, undef ) if ( $msg->{key} // '' ) eq 'q';
    $self->{count}++;
    return ( $self, undef );
}

sub view {
    my ($self) = @_;
    return view_for( $self->{w}, $self->{h}, $self->{count} );
}

# Pure: build the laid-out frame for a given size and counter value.
sub view_for {
    my ( $w, $h, $count ) = @_;

    my $header = PerlTea::Style->new(
        width      => $w - 2,        # interior; +2 for the border == full width
        border     => 'single',
        align      => 'center',
        bold       => 1,
        foreground => 'bright-white',
        background => 'blue',
    )->render('PerlTea G5 — Layout');

    my $body = join "\n",
        "Terminal size: ${w}x${h}",
        "Frame: $count",
        '',
        'The body flexes to fill the space between the header',
        'and the footer. Resize the terminal — it reflows with',
        'no absolute coordinates, only stacks and flexible sizes.';

    my $footer = PerlTea::Style->new(
        width      => $w,
        align      => 'left',
        faint      => 1,
        foreground => 'cyan',
    )->render('press any key to advance · q to quit');

    return PerlTea::Layout->vertical(
        width    => $w,
        height   => $h,
        children => [
            { content => $header, size => 3 },    # border + 1 content row
            { content => $body,   flex => 1 },    # fills the remaining rows
            { content => $footer, size => 1 },    # one-line status bar
        ],
    )->render;
}

package main;

# Only run the event loop when executed directly; when require'd by the snapshot
# test, caller() is true so we just expose G5Demo::view_for.
PerlTea->new( model => G5Demo->new, alt_screen => 1 )->run unless caller;

1;
