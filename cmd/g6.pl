#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use PerlTea;
use PerlTea::Layout;
use PerlTea::Component::Viewport;
use PerlTea::Component::List;
use PerlTea::Component::TextInput;
use PerlTea::Component::Spinner;
use PerlTea::Component::Paginator;
use PerlTea::Component::Help;

{
    package G6Demo;

    sub new {
        my ($class) = @_;
        my $self = bless {
            width  => 80,
            height => 24,
            focus  => 0,
            names  => [qw(list input viewport)],
            list   => PerlTea::Component::List->new(
                width  => 24,
                height => 6,
                items  => [
                    'Viewport',
                    'List',
                    'TextInput',
                    'Spinner',
                    'Paginator',
                    'Help',
                ],
                focus => 1,
            ),
            input => PerlTea::Component::TextInput->new(
                width       => 24,
                placeholder => 'type filter',
            ),
            viewport => PerlTea::Component::Viewport->new(
                width   => 50,
                height  => 10,
                content => join(
                    "\n",
                    'PerlTea G6 composite demo',
                    '',
                    'Tab moves focus between components.',
                    'Up/down changes list or scrolls viewport.',
                    'Printable keys edit the text input.',
                    '',
                    'Components on screen:',
                    '- viewport',
                    '- list',
                    '- text-input',
                    '- spinner',
                    '- paginator',
                    '- help-bar',
                ),
            ),
            spinner  => PerlTea::Component::Spinner->new( label => 'ready' ),
            pager    => PerlTea::Component::Paginator->new( total => 3 ),
            help     => PerlTea::Component::Help->new(
                bindings => [
                    [ tab => 'focus' ],
                    [ q   => 'quit' ],
                    [ arrows => 'move' ],
                ],
            ),
        }, $class;
        $self->_sync_focus;
        return $self;
    }

    sub subscriptions {
        return [ { every => 0.25, msg => sub { return { type => 'tick' } } } ];
    }

    sub update {
        my ( $self, $msg ) = @_;
        return ( $self, undef ) unless $msg && ref $msg eq 'HASH';

        if ( $msg->{type} && $msg->{type} eq 'resize' ) {
            $self->{width}  = $msg->{width};
            $self->{height} = $msg->{height};
            return ( $self, undef );
        }

        if ( $msg->{type} && $msg->{type} eq 'tick' ) {
            $self->{spinner}->tick;
            return ( $self, undef );
        }

        my $key = $msg->{key} // '';
        return ( PerlTea->quit, undef ) if $key eq 'q';

        if ( $key eq 'tab' ) {
            $self->{focus} = ( $self->{focus} + 1 ) % @{ $self->{names} };
            $self->_sync_focus;
            return ( $self, undef );
        }

        my $focused = $self->{names}[ $self->{focus} ];
        if ( $focused eq 'list' ) {
            $self->{list}->move_up   if $key eq 'up';
            $self->{list}->move_down if $key eq 'down';
        }
        elsif ( $focused eq 'input' ) {
            $self->{input}->handle_msg($msg);
        }
        elsif ( $focused eq 'viewport' ) {
            $self->{viewport}->scroll_up      if $key eq 'up';
            $self->{viewport}->scroll_down    if $key eq 'down';
            $self->{viewport}->page_up        if $key eq 'pgup';
            $self->{viewport}->page_down      if $key eq 'pgdown';
            $self->{viewport}->goto_top       if $key eq 'home';
            $self->{viewport}->goto_bottom    if $key eq 'end';
        }

        return ( $self, undef );
    }

    sub view {
        my ($self) = @_;
        my $w = $self->{width}  || 80;
        my $h = $self->{height} || 24;
        $w = 40 if $w < 40;
        $h = 12 if $h < 12;

        my $left_w = $w < 70 ? 20 : 28;
        my $right_w = $w - $left_w - 1;
        $right_w = 10 if $right_w < 10;

        $self->{list}->{width} = $left_w;
        $self->{input}->{width} = $left_w;
        $self->{viewport}->resize( width => $right_w, height => $h - 6 );
        $self->{help}->{width} = $w;

        my $focused = $self->{names}[ $self->{focus} ];
        my $title = 'G6 components - focus: ' . $focused;
        my $left = join "\n",
            _section( 'list',      $focused eq 'list',      $self->{list}->view ),
            _section( 'textinput', $focused eq 'input',     $self->{input}->view ),
            _section( 'spinner',   0,                       $self->{spinner}->view ),
            _section( 'paginator', 0,                       $self->{pager}->view );
        my $right = _section(
            'viewport',
            $focused eq 'viewport',
            $self->{viewport}->view,
        );

        my $body = PerlTea::Layout->horizontal(
            width    => $w,
            height   => $h - 3,
            children => [
                { content => $left, size => $left_w },
                { content => ' ',   size => 1 },
                { content => $right, flex => 1 },
            ],
        )->render;

        return PerlTea::Layout->vertical(
            width    => $w,
            height   => $h,
            children => [
                { content => _fit( $title, $w ), size => 1 },
                { content => $body,              flex => 1 },
                { content => $self->{help}->view, size => 1 },
            ],
        )->render;
    }

    sub _sync_focus {
        my ($self) = @_;
        my $focused = $self->{names}[ $self->{focus} ];
        $self->{list}->set_focus( $focused eq 'list' );
        $self->{input}->set_focus( $focused eq 'input' );
        return;
    }

    sub _section {
        my ( $name, $active, $body ) = @_;
        my $mark = $active ? '[*] ' : '[ ] ';
        return $mark . $name . "\n" . $body;
    }

    sub _fit {
        my ( $line, $width ) = @_;
        $line = substr( $line, 0, $width ) if length($line) > $width;
        return $line . ( ' ' x ( $width - length($line) ) );
    }
}

PerlTea->new( model => G6Demo->new, alt_screen => 1 )->run unless caller;
1;
