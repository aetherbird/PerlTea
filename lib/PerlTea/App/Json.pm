package PerlTea::App::Json;

use strict;
use warnings;

use JSON::PP ();
use PerlTea ();
use PerlTea::Component::TextInput ();

=head1 NAME

PerlTea::App::Json - a keyboard-driven JSON structure explorer

=head1 SYNOPSIS

    my $app = PerlTea::App::Json->new( path => 'data.json' );
    PerlTea->new( model => $app, alt_screen => 1 )->run;

=head1 DESCRIPTION

C<PerlTea::App::Json> loads a JSON document, renders the top-level structure,
lets the user expand/collapse objects and arrays, and provides a small jq-like
path filter. The filter intentionally supports a deterministic subset:
C<.key>, C<.key.nested>, and array indexes such as C<.items[0]>.

Keys: C<up>/C<k> and C<down>/C<j> move; C<Enter>/Right expands or collapses;
C<Left> collapses; C</> opens the filter prompt; C<q> quits.

=cut

=head2 new

    my $app = PerlTea::App::Json->new( path => $file );
    my $app = PerlTea::App::Json->new( data => $data, width => 80, height => 24 );

Construct the model from either a JSON file path or an already-decoded Perl data
structure. Width and height default to 80x24 and are corrected by PerlTea's
startup resize message.

=cut

sub new {
    my ( $class, %args ) = @_;

    my ( $data, $error );
    if ( exists $args{data} ) {
        $data = $args{data};
    }
    elsif ( defined $args{path} ) {
        ( $data, $error ) = load_document( $args{path} );
    }
    else {
        $data = {};
    }

    my $self = bless {
        path         => $args{path} || '',
        data         => $data,
        load_error   => $error || '',
        width        => $args{width}  || 80,
        height       => $args{height} || 24,
        expanded     => { '' => 1 },
        selected     => 0,
        filter_mode  => 0,
        filter_expr  => '',
        filter_error => '',
        filter_node  => undef,
        filter_path  => [],
    }, $class;

    $self->_rebuild_input;
    return $self;
}

=head2 init

Return the initial command (none); the document is loaded synchronously in the
constructor so the first frame is populated.

=cut

sub init { return undef }

=head2 update

Fold a PerlTea message. Resize changes the render size. C<q>/C<Ctrl-C> quit.
The filter prompt handles printable keys while active; C<Enter> applies it and
syntax/path errors are shown in the UI instead of throwing.

=cut

sub update {
    my ( $self, $msg ) = @_;
    my $type = $msg->{type} // '';

    if ( $type eq 'resize' ) {
        $self->{width}  = $msg->{width}  if $msg->{width};
        $self->{height} = $msg->{height} if $msg->{height};
        $self->_rebuild_input;
        return ( $self, undef );
    }

    my $key = $msg->{key} // '';
    return ( PerlTea->quit, undef ) if $key eq 'q' || $key eq 'ctrl+c';

    if ( $self->{filter_mode} ) {
        if ( $key eq 'enter' ) {
            $self->{filter_mode} = 0;
            $self->_apply_filter( $self->{input}->value );
            return ( $self, undef );
        }
        if ( $key eq 'esc' ) {
            $self->{filter_mode} = 0;
            $self->_rebuild_input;
            return ( $self, undef );
        }
        $self->{input}->handle_msg($msg);
        return ( $self, undef );
    }

    if ( $key eq '/' ) {
        $self->{filter_mode} = 1;
        $self->_rebuild_input;
        return ( $self, undef );
    }
    if ( $key eq 'up' || $key eq 'k' ) {
        $self->{selected}-- if $self->{selected} > 0;
        return ( $self, undef );
    }
    if ( $key eq 'down' || $key eq 'j' ) {
        my @rows = $self->_rows;
        $self->{selected}++ if $self->{selected} < @rows - 1;
        return ( $self, undef );
    }
    if ( $key eq 'enter' || $key eq 'right' || $key eq 'l' ) {
        $self->_toggle_or_expand_selected;
        return ( $self, undef );
    }
    if ( $key eq 'left' || $key eq 'h' || $key eq 'backspace' ) {
        $self->_collapse_selected;
        return ( $self, undef );
    }

    return ( $self, undef );
}

=head2 view

Render the document header, optional filter prompt/status, visible structure rows,
and a help footer.

=cut

sub view {
    my ($self) = @_;
    my $w = $self->{width}  > 0 ? $self->{width}  : 80;
    my $h = $self->{height} > 4 ? $self->{height} : 5;

    my @out;
    my $title = length $self->{path} ? $self->{path} : '(memory)';
    push @out, _fit( "json: $title", $w );

    if ( length $self->{load_error} ) {
        push @out, _fit( 'Error: ' . $self->{load_error}, $w );
    }
    elsif ( $self->{filter_mode} ) {
        push @out, _fit( 'Filter: ' . $self->{input}->view, $w );
    }
    elsif ( length $self->{filter_error} ) {
        push @out, _fit( 'Filter error: ' . $self->{filter_error}, $w );
    }
    elsif ( length $self->{filter_expr} ) {
        push @out, _fit( 'Filter: ' . $self->{filter_expr}, $w );
    }
    else {
        push @out, _fit( 'Filter: (none)', $w );
    }

    my $footer = 'q: quit   /: filter   enter/right: expand   left: collapse';
    my $body_h = $h - @out - 1;
    $body_h = 0 if $body_h < 0;

    my @rows = $self->_rows;
    @rows = ( { text => '(empty)', path => [] } ) unless @rows;
    $self->_clamp_selected( scalar @rows );

    for my $i ( 0 .. $body_h - 1 ) {
        my $row = $rows[$i];
        if ($row) {
            my $mark = $i == $self->{selected} ? '>' : ' ';
            push @out, _fit( $mark . ' ' . $row->{text}, $w );
        }
        else {
            push @out, _fit( '', $w );
        }
    }

    push @out, _fit( $footer, $w );
    return join "\n", @out;
}

# -- pure document helpers ----------------------------------------------------

=head2 load_document

    my ( $data, $error ) = PerlTea::App::Json::load_document($path);

Read and decode a JSON document. On success C<$error> is empty. On failure,
C<$data> is C<undef> and C<$error> is a cleaned diagnostic suitable for display.

=cut

sub load_document {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or return ( undef, "cannot open $path: $!" );
    local $/;
    my $text = <$fh>;
    close $fh;

    my $data = eval { JSON::PP->new->utf8->decode($text) };
    if ($@) {
        return ( undef, _clean_json_error($@) );
    }
    return ( $data, '' );
}

=head2 visible_rows

    my @rows = PerlTea::App::Json::visible_rows($data, \%expanded);

Return render rows for the currently expanded tree. Each row is a hash with
C<path>, C<depth>, C<text>, and C<expandable>.

=cut

sub visible_rows {
    my ( $data, $expanded ) = @_;
    $expanded ||= { '' => 1 };
    my @rows;
    _push_rows( \@rows, $data, [], 'root', 0, $expanded );
    return @rows;
}

=head2 node_at_path

    my ( $node, $error ) = PerlTea::App::Json::node_at_path($data, \@path);

Return the node at C<@path>, where hash keys and array indexes are represented
as path elements.

=cut

sub node_at_path {
    my ( $data, $path ) = @_;
    my $node = $data;
    for my $part (@$path) {
        if ( ref($node) eq 'HASH' ) {
            return ( undef, "missing key: $part" ) unless exists $node->{$part};
            $node = $node->{$part};
        }
        elsif ( ref($node) eq 'ARRAY' ) {
            return ( undef, "not an array index: $part" )
                unless defined($part) && $part =~ /\A\d+\z/;
            return ( undef, "array index out of range: $part" )
                if $part >= @$node;
            $node = $node->[$part];
        }
        else {
            return ( undef, "cannot descend into scalar at $part" );
        }
    }
    return ( $node, '' );
}

=head2 filter_path

    my ( $node, $path, $error ) = PerlTea::App::Json::filter_path($data, '.meta.sentinel');

Apply the built-in jq-like path subset. Empty filters return the original root.

=cut

sub filter_path {
    my ( $data, $expr ) = @_;
    $expr = '' unless defined $expr;
    $expr =~ s/\A\s+//;
    $expr =~ s/\s+\z//;
    return ( $data, [], '' ) unless length $expr;

    my ( $path, $parse_error ) = parse_filter($expr);
    return ( undef, [], $parse_error ) if length $parse_error;

    my ( $node, $path_error ) = node_at_path( $data, $path );
    return ( undef, $path, $path_error ) if length $path_error;
    return ( $node, $path, '' );
}

=head2 parse_filter

    my ( $path, $error ) = PerlTea::App::Json::parse_filter('.apps[0]');

Parse the supported filter subset into path parts.

=cut

sub parse_filter {
    my ($expr) = @_;
    $expr = '' unless defined $expr;
    $expr =~ s/\A\s+//;
    $expr =~ s/\s+\z//;
    return ( [], '' ) unless length $expr;
    $expr =~ s/\A\.//;

    my @path;
    pos($expr) = 0;
    while ( pos($expr) < length($expr) ) {
        if ( $expr =~ /\G([A-Za-z_][A-Za-z0-9_-]*)/gc ) {
            push @path, $1;
        }
        elsif ( $expr =~ /\G\["([^"\\]*(?:\\.[^"\\]*)*)"\]/gc ) {
            my $key = $1;
            $key =~ s/\\(["\\])/$1/g;
            push @path, $key;
        }
        elsif ( $expr =~ /\G\[(\d+)\]/gc ) {
            push @path, $1;
        }
        else {
            return ( [], 'expected .key or [index]' );
        }

        if ( pos($expr) < length($expr) ) {
            if ( $expr =~ /\G\./gc ) {
                next;
            }
            elsif ( substr( $expr, pos($expr), 1 ) eq '[' ) {
                next;
            }
            return ( [], 'expected . or [index]' );
        }
    }

    return ( \@path, '' );
}

# -- internals ---------------------------------------------------------------

sub _rows {
    my ($self) = @_;
    return () unless defined $self->{data};
    if ( length $self->{filter_expr} && !length $self->{filter_error} ) {
        my %expanded = ( '' => 1 );
        return visible_rows( $self->{filter_node}, \%expanded );
    }
    return visible_rows( $self->{data}, $self->{expanded} );
}

sub _apply_filter {
    my ( $self, $expr ) = @_;
    $expr = '' unless defined $expr;
    my ( $node, $path, $error ) = filter_path( $self->{data}, $expr );
    $self->{filter_expr}  = $expr;
    $self->{filter_error} = $error || '';
    $self->{filter_node}  = $node;
    $self->{filter_path}  = $path || [];
    $self->{selected}     = 0;
    $self->_rebuild_input;
    return;
}

sub _toggle_or_expand_selected {
    my ($self) = @_;
    return if length $self->{filter_expr} && !length $self->{filter_error};
    my @rows = $self->_rows;
    my $row  = $rows[ $self->{selected} ];
    return unless $row && $row->{expandable};
    my $key = _path_key( $row->{path} );
    $self->{expanded}{$key} = $self->{expanded}{$key} ? 0 : 1;
    return;
}

sub _collapse_selected {
    my ($self) = @_;
    return if length $self->{filter_expr} && !length $self->{filter_error};
    my @rows = $self->_rows;
    my $row  = $rows[ $self->{selected} ];
    return unless $row;
    my $key = _path_key( $row->{path} );
    if ( $row->{expandable} && $self->{expanded}{$key} ) {
        $self->{expanded}{$key} = 0;
        return;
    }
    return unless @{ $row->{path} };
    my @parent = @{ $row->{path} };
    pop @parent;
    my $parent_key = _path_key( \@parent );
    for my $i ( 0 .. $#rows ) {
        if ( _path_key( $rows[$i]{path} ) eq $parent_key ) {
            $self->{selected} = $i;
            last;
        }
    }
    return;
}

sub _rebuild_input {
    my ($self) = @_;
    my $w = $self->{width} > 10 ? $self->{width} - 10 : 1;
    $self->{input} = PerlTea::Component::TextInput->new(
        width       => $w,
        value       => $self->{filter_expr},
        placeholder => '.meta.sentinel',
        focus       => $self->{filter_mode},
    );
    return;
}

sub _clamp_selected {
    my ( $self, $count ) = @_;
    $self->{selected} = 0 if $self->{selected} < 0;
    $self->{selected} = $count - 1 if $count > 0 && $self->{selected} >= $count;
    $self->{selected} = 0 if $count <= 0;
    return;
}

sub _push_rows {
    my ( $rows, $node, $path, $label, $depth, $expanded ) = @_;
    my $path_key    = _path_key($path);
    my $expandable  = _is_container($node);
    my $is_expanded = $expanded->{$path_key} ? 1 : 0;
    my $prefix      = $expandable ? ( $is_expanded ? 'v ' : '> ' ) : '- ';
    my $indent      = '  ' x $depth;
    push @$rows, {
        path       => [@$path],
        depth      => $depth,
        expandable => $expandable,
        text       => $indent . $prefix . $label . ': ' . _summary($node),
    };

    return unless $expandable && $is_expanded;
    if ( ref($node) eq 'HASH' ) {
        for my $key ( sort keys %$node ) {
            _push_rows( $rows, $node->{$key}, [ @$path, $key ], $key,
                $depth + 1, $expanded );
        }
    }
    elsif ( ref($node) eq 'ARRAY' ) {
        for my $i ( 0 .. $#$node ) {
            _push_rows( $rows, $node->[$i], [ @$path, $i ], "[$i]",
                $depth + 1, $expanded );
        }
    }
    return;
}

sub _summary {
    my ($node) = @_;
    if ( ref($node) eq 'HASH' ) {
        my $n = scalar keys %$node;
        return "{$n keys}";
    }
    if ( ref($node) eq 'ARRAY' ) {
        return '[' . scalar(@$node) . ' items]';
    }
    return _scalar_value($node);
}

sub _scalar_value {
    my ($value) = @_;
    return 'null' unless defined $value;
    return $value ? 'true' : 'false' if JSON::PP::is_bool($value);
    if ( !ref($value) && $value =~ /\A-?(?:0|[1-9]\d*)(?:\.\d+)?\z/ ) {
        return $value;
    }
    my $s = "$value";
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    return '"' . $s . '"';
}

sub _is_container {
    my ($node) = @_;
    return ref($node) eq 'HASH' || ref($node) eq 'ARRAY';
}

sub _path_key {
    my ($path) = @_;
    return join "\x1f", @$path;
}

sub _fit {
    my ( $line, $width ) = @_;
    $line = '' unless defined $line;
    $line = substr( $line, 0, $width ) if length($line) > $width;
    return $line . ( ' ' x ( $width - length($line) ) );
}

sub _clean_json_error {
    my ($err) = @_;
    $err = '' unless defined $err;
    $err =~ s/ at .* line \d+.*//s;
    $err =~ s/\s+\z//;
    return $err || 'invalid JSON';
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
