#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use PerlTea;
use PerlTea::App::Glow;

# A1 demo — glow markdown renderer. Reads a Markdown file given as the first
# argument, renders it to ANSI-styled text via PerlTea::App::Glow (the G4
# styling layer), and shows it. 'q' quits; the terminal is restored on exit.
#
# Scrolling/navigation is A2's job — this demo simply renders the document.

package A1Demo;

sub new {
    my ( $class, %args ) = @_;
    return bless { content => $args{content} }, $class;
}

sub init { return undef }

sub update {
    my ( $self, $msg ) = @_;
    return ( PerlTea->quit, undef ) if ( $msg->{key} // '' ) eq 'q';
    return ( $self, undef );
}

sub view { return $_[0]->{content} }

package main;

unless (caller) {
    my $file = shift @ARGV;
    die "usage: a1.pl <file.md>\n" unless defined $file && length $file;
    open my $fh, '<:encoding(UTF-8)', $file or die "cannot open $file: $!\n";
    local $/;
    my $markdown = <$fh>;
    close $fh;

    my $rendered = PerlTea::App::Glow::render( $markdown, width => 80 );

    PerlTea->new( model => A1Demo->new( content => $rendered ), alt_screen => 1 )
        ->run;
}

1;
