#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;
use PerlTea::App::Glow;
use PerlTea::Component::Viewport;

# A2 demo — glow markdown navigator. Reads a Markdown file given as the first
# argument, renders it through PerlTea::App::Glow, and displays it in a
# scrollable viewport (PerlTea::Component::Viewport from G6).
#
# Keys:
#   q          quit
#   up/k       scroll up one line
#   down/j     scroll down one line
#   pgup       scroll up one page
#   pgdown     scroll down one page
#   g/home     jump to top
#   G/end      jump to bottom

package A2Demo;

sub new {
    my ( $class, %args ) = @_;
    my $self = bless {
        path   => $args{path},
        width  => $args{width}  || 80,
        height => $args{height} || 24,
    }, $class;
    $self->_load;
    return $self;
}

sub _load {
    my ($self) = @_;
    open my $fh, '<:encoding(UTF-8)', $self->{path}
        or die "cannot open $self->{path}: $!\n";
    local $/;
    my $markdown = <$fh>;
    close $fh;

    my $rendered = PerlTea::App::Glow::render( $markdown, width => $self->{width} );
    $self->{viewport} = PerlTea::Component::Viewport->new(
        width   => $self->{width},
        height  => $self->{height},
        content => $rendered,
    );
    return $self;
}

sub init { return undef }

sub update {
    my ( $self, $msg ) = @_;

    if ( ( $msg->{type} // '' ) eq 'resize' ) {
        $self->{width}  = $msg->{width}  if $msg->{width};
        $self->{height} = $msg->{height} if $msg->{height};
        $self->_load;
        return ( $self, undef );
    }

    return ( PerlTea->quit, undef ) if ( $msg->{key} // '' ) eq 'q';

    my $key = $msg->{key} // '';
    my $vp  = $self->{viewport};

    if    ( $key eq 'up' || $key eq 'k' )     { $vp->scroll_up }
    elsif ( $key eq 'down' || $key eq 'j' )   { $vp->scroll_down }
    elsif ( $key eq 'pgup' )                  { $vp->page_up }
    elsif ( $key eq 'pgdown' )                { $vp->page_down }
    elsif ( $key eq 'home' || $key eq 'g' )   { $vp->goto_top }
    elsif ( $key eq 'end' || $key eq 'G' )    { $vp->goto_bottom }

    return ( $self, undef );
}

sub view { return $_[0]->{viewport}->view }

package main;

unless (caller) {
    my $file = shift @ARGV;
    die "usage: a2.pl <file.md>\n" unless defined $file && length $file;

    PerlTea->new( model => A2Demo->new( path => $file ), alt_screen => 1 )->run;
}

1;
