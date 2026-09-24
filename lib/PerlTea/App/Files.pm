package PerlTea::App::Files;

use strict;
use warnings;
use utf8;

use PerlTea ();
use PerlTea::App::Glow ();
use PerlTea::Component::List ();
use PerlTea::Component::Viewport ();
use PerlTea::Style ();

=head1 NAME

PerlTea::App::Files - a dual-pane keyboard-driven file manager

=head1 SYNOPSIS

    use PerlTea::App::Files;
    my $app = PerlTea::App::Files->new( path => '.' );
    PerlTea->new( model => $app, alt_screen => 1 )->run;

=head1 DESCRIPTION

C<PerlTea::App::Files> is a small dual-pane file manager: the left pane lists the
current directory, the right pane previews the selected file. Markdown files are
rendered through C<PerlTea::App::Glow>; other files are shown as plain text.

Keys: C<up>/C<k> and C<down>/C<j> move the selection in the file list or scroll
the preview, depending on which pane is focused. C<Tab> switches focus. C<Enter>
(or C<right>/C<l>) descends into the selected directory. C<Left>/C<h>/C<backspace>
returns to the parent directory. C<q> quits.

=cut

=head2 new

    my $app = PerlTea::App::Files->new( path => $dir );
    my $app = PerlTea::App::Files->new( path => $dir, width => 80, height => 24 );

Construct the model rooted at C<path> (default C<.>). Width and height are
corrected by the startup resize message.

=cut

sub new {
    my ( $class, %args ) = @_;

    my $path = defined $args{path} ? $args{path} : '.';
    $path = _canonical($path);

    my $self = bless {
        path           => $path,
        width          => $args{width}  || 80,
        height         => $args{height} || 24,
        focus          => 'list',
        selected       => 0,
        preview_offset => 0,
        entries        => [],
        preview_content => '',
        error          => '',
        color_profile  => $args{color_profile} || _detect_profile(),
    }, $class;

    $self->_load;
    return $self;
}

=head2 init

Return the initial command (none); the directory is scanned synchronously in the
constructor so the first frame is populated.

=cut

sub init { return undef }

=head2 update

    my ( $model, $cmd ) = $app->update($msg);

Fold a PerlTea message. C<q>/C<Ctrl-C> quit. C<Tab> switches focus between the
file list and the preview pane. Arrow keys move the selection or scroll the
preview. C<Enter>/C<right>/C<l> descends into a directory; C<left>/C<h>/
C<backspace> returns to the parent.

=cut

sub update {
    my ( $self, $msg ) = @_;
    my $type = $msg->{type} // '';

    if ( $type eq 'resize' ) {
        $self->{width}  = $msg->{width}  if $msg->{width};
        $self->{height} = $msg->{height} if $msg->{height};
        $self->_rebuild_preview;
        return ( $self, undef );
    }

    my $key = $msg->{key} // '';
    return ( PerlTea->quit, undef ) if $key eq 'q' || $key eq 'ctrl+c';

    if ( $key eq 'tab' ) {
        $self->{focus} = $self->{focus} eq 'list' ? 'preview' : 'list';
        return ( $self, undef );
    }

    if ( $self->{focus} eq 'preview' ) {
        if ( $key eq 'up' || $key eq 'k' ) {
            $self->{preview_offset}-- if $self->{preview_offset} > 0;
            return ( $self, undef );
        }
        if ( $key eq 'down' || $key eq 'j' ) {
            $self->{preview_offset}++;
            return ( $self, undef );
        }
        if ( $key eq 'pgup' ) {
            $self->{preview_offset} -= _body_height( $self->{height} );
            $self->{preview_offset} = 0 if $self->{preview_offset} < 0;
            return ( $self, undef );
        }
        if ( $key eq 'pgdown' ) {
            $self->{preview_offset} += _body_height( $self->{height} );
            return ( $self, undef );
        }
        if ( $key eq 'home' || $key eq 'g' ) {
            $self->{preview_offset} = 0;
            return ( $self, undef );
        }
        if ( $key eq 'end' || $key eq 'G' ) {
            $self->{preview_offset} = 999_999;
            return ( $self, undef );
        }
    }

    # File-list focus (also the default for unknown keys).
    if ( $key eq 'up' || $key eq 'k' ) {
        if ( $self->{selected} > 0 ) {
            $self->{selected}--;
            $self->_rebuild_preview;
        }
        return ( $self, undef );
    }
    if ( $key eq 'down' || $key eq 'j' ) {
        if ( $self->{selected} < @{ $self->{entries} } - 1 ) {
            $self->{selected}++;
            $self->_rebuild_preview;
        }
        return ( $self, undef );
    }
    if ( $key eq 'home' || $key eq 'g' ) {
        $self->{selected} = 0;
        $self->_rebuild_preview;
        return ( $self, undef );
    }
    if ( $key eq 'end' || $key eq 'G' ) {
        $self->{selected} = @{ $self->{entries} } - 1;
        $self->_rebuild_preview;
        return ( $self, undef );
    }

    if ( $key eq 'enter' || $key eq 'right' || $key eq 'l' ) {
        $self->_descend;
        return ( $self, undef );
    }

    if (   $key eq 'left'
        || $key eq 'h'
        || $key eq 'backspace' )
    {
        $self->_ascend;
        return ( $self, undef );
    }

    return ( $self, undef );
}

=head2 view

Render the header, dual-pane body, and help footer.

=cut

sub view {
    my ($self) = @_;
    my $w = $self->{width}  > 0 ? $self->{width}  : 80;
    my $h = $self->{height} > 4 ? $self->{height} : 5;

    my $list_w    = _list_width($w);
    my $preview_w = $w - $list_w - 1;
    my $body_h    = _body_height($h);

    # Reserve the top body row for pane titles; the rest is content.
    my $pane_titles_h = 1;
    my $content_h     = $body_h - $pane_titles_h;
    $content_h = 1 if $content_h < 1;

    my @items = map { $_->{name} . ( $_->{is_dir} ? '/' : '' ) }
        @{ $self->{entries} };
    @items = ('(empty directory)') unless @items;

    my $list = PerlTea::Component::List->new(
        items    => \@items,
        width    => $list_w,
        height   => $content_h,
        selected => $self->{selected},
        focus    => $self->{focus} eq 'list',
    );

    my $preview = PerlTea::Component::Viewport->new(
        width   => $preview_w,
        height  => $content_h,
        content => $self->{preview_content},
        offset  => $self->{preview_offset},
    );

    my @list_lines    = split /\n/, $list->view;
    my @preview_lines = split /\n/, $preview->view;

    # Pane titles: left = current directory, right = selected entry + type.
    my $list_focused = $self->{focus} eq 'list';
    my $list_title = _pane_title( ' ' . _basename( $self->{path} ) . '/ ',
        $list_w, $list_focused, $self->{color_profile} );
    my $preview_title = _pane_title( ' ' . $self->_preview_header . ' ',
        $preview_w, !$list_focused, $self->{color_profile} );

    my $header = $self->_render_header($w);
    my $footer = $self->_render_footer($w);

    my $div = $list_focused ? '│' : '┃';

    my @out;
    push @out, $header;
    push @out, $list_title . $div . $preview_title;
    for my $i ( 0 .. $content_h - 1 ) {
        my $ll = $list_lines[$i]    // '';
        my $pl = $preview_lines[$i] // '';
        push @out, _fit( $ll, $list_w ) . $div . _fit( $pl, $preview_w );
    }
    push @out, $footer;

    return join "\n", @out;
}

# Header for the selected entry, e.g. "readme.md (file)" / "sub/ (directory)".
sub _preview_header {
    my ($self) = @_;
    my $entry = $self->{entries}[ $self->{selected} ];
    return 'preview' unless $entry;
    my $kind = $entry->{is_dir} ? 'directory' : 'file';
    my $name = $entry->{name} . ( $entry->{is_dir} ? '/' : '' );
    return "$name ($kind)";
}

# A reversed (or plain) pane-title bar, fitted to the column width.
sub _pane_title {
    my ( $text, $width, $focused, $profile ) = @_;
    $width = 1 if $width < 1;
    my $style = PerlTea::Style->new(
        width         => $width,
        height        => 1,
        reverse       => $focused ? 1 : 0,
        bold          => 1,
        align         => 'left',
        color_profile => $profile,
    );
    return $style->render($text);
}

sub _render_header {
    my ( $self, $w ) = @_;
    my $style = PerlTea::Style->new(
        width         => $w,
        height        => 1,
        reverse       => 1,
        align         => 'left',
        color_profile => $self->{color_profile},
    );
    return $style->render( ' PerlTea Files: ' . $self->{path} . ' ' );
}

sub _render_footer {
    my ( $self, $w ) = @_;
    my $style = PerlTea::Style->new(
        width         => $w,
        height        => 1,
        align         => 'center',
        color_profile => $self->{color_profile},
    );
    return $style->render(
        'q: quit   tab: pane   up/down: move   enter: open   left: up' );
}

sub _basename {
    my ($path) = @_;
    return '/' if $path eq '/';
    $path =~ s{/+\z}{};
    return $1 if $path =~ m{/([^/]+)\z};
    return $path eq '.' ? '.' : $path;
}

sub _detect_profile {
    return '16' if ( $ENV{PERLTEA_FORCE_COLORS} // '' ) eq '16';
    my $ct = lc( $ENV{COLORTERM} // '' );
    return 'truecolor' if $ct eq 'truecolor' || $ct eq '24bit';
    my $term = lc( $ENV{TERM} // '' );
    return '256'       if $term =~ /256/;
    return 'truecolor' if $term =~ /truecolor|24bit/;
    return '16';
}

# ── pure directory/preview engine (unit tested directly) ───────────────────────

=head2 list_dir

    my $entries = PerlTea::App::Files::list_dir($dir);

Return an arrayref of entries under C<$dir>. Each entry is a hash with
C<name>, C<path>, and C<is_dir>. Entries are sorted with directories first,
then alphabetically by name. An unreadable directory yields an empty list.

=cut

sub list_dir {
    my ($dir) = @_;

    my @entries;
    if ( opendir my $dh, $dir ) {
        my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        for my $name (@names) {
            my $path   = "$dir/$name";
            my $is_dir = ( -d $path && !-l $path ) ? 1 : 0;
            push @entries,
                { name => $name, path => $path, is_dir => $is_dir };
        }
    }

    @entries = sort {
        ( $b->{is_dir} <=> $a->{is_dir} )
            || ( $a->{name} cmp $b->{name} )
    } @entries;

    return \@entries;
}

=head2 preview_for

    my $text = PerlTea::App::Files::preview_for($path, $width);

Return a preview string for C<$path>. A directory previews as its own listing
(a summary line followed by each child entry, directories suffixed with C</>),
so the preview pane shows real content rather than a single placeholder line.
Markdown files are rendered through C<PerlTea::App::Glow>; other readable files
are returned as plain text. Unreadable paths render an error message instead of
dying.

=cut

sub preview_for {
    my ( $path, $width ) = @_;
    $width ||= 80;

    if ( !-e $path ) {
        return "(does not exist)";
    }

    if ( -d $path ) {
        my $entries = list_dir($path);
        my $n = scalar @$entries;
        my @lines = '<directory: ' . $n . ' ' . ( $n == 1 ? 'entry' : 'entries' ) . '>';
        push @lines, '' if @$entries;
        for my $e (@$entries) {
            push @lines, $e->{name} . ( $e->{is_dir} ? '/' : '' );
        }
        push @lines, '(empty)' unless @$entries;
        return join "\n", @lines;
    }

    open my $fh, '<', $path
        or return "(cannot read: $!)";
    local $/;
    my $text = <$fh> // '';
    close $fh;

    if ( $path =~ /\.md\z/i ) {
        return PerlTea::App::Glow::render( $text, width => $width );
    }

    return $text;
}

# ── internals ──────────────────────────────────────────────────────────────────

sub _load {
    my ($self) = @_;

    if ( !-d $self->{path} ) {
        $self->{entries}        = [];
        $self->{selected}       = 0;
        $self->{preview_offset} = 0;
        $self->{preview_content} = "(not a directory)";
        $self->{error}          = "not a directory: $self->{path}";
        return;
    }

    $self->{entries}        = list_dir( $self->{path} );
    $self->{selected}       = 0;
    $self->{preview_offset} = 0;
    $self->_rebuild_preview;
    return;
}

sub _rebuild_preview {
    my ($self) = @_;

    my $entry = $self->{entries}[ $self->{selected} ];
    if ( !$entry ) {
        $self->{preview_content} = '';
        return;
    }

    my $w = _pane_width( $self->{width}, 'preview' );
    $w = 20 if $w < 20;
    $self->{preview_content} = preview_for( $entry->{path}, $w );
    $self->{preview_offset}  = 0;
    return;
}

sub _descend {
    my ($self) = @_;
    return unless @{ $self->{entries} };

    my $entry = $self->{entries}[ $self->{selected} ];
    return unless $entry && $entry->{is_dir};

    $self->{path} = $entry->{path};
    $self->_load;
    $self->{focus} = 'list';
    return;
}

sub _ascend {
    my ($self) = @_;

    my $path = $self->{path};
    return if $path eq '/';

    # Remove trailing slash for the dirname calculation.
    $path =~ s{/+\z}{};
    my $parent = $path =~ m{/} ? $path =~ s{/[^/]+\z}{}r : '.';
    $parent = '.' if $parent eq '';

    my $prev_name = '';
    if ( $path =~ m{/([^/]+)\z} ) {
        $prev_name = $1;
    }
    elsif ( $path ne '.' && $path ne '/' ) {
        $prev_name = $path;
    }

    $self->{path} = _canonical($parent);
    $self->_load;

    # Try to keep the selection on the directory we just came from.
    if ( length $prev_name ) {
        for my $i ( 0 .. @{ $self->{entries} } - 1 ) {
            if ( $self->{entries}[$i]{name} eq $prev_name ) {
                $self->{selected} = $i;
                $self->_rebuild_preview;
                last;
            }
        }
    }

    $self->{focus} = 'list';
    return;
}

sub _list_width {
    my ($total) = @_;
    my $w = int( $total * 0.35 );
    $w = 20 if $w < 20;
    $w = 50 if $w > 50;
    return $w;
}

sub _body_height {
    my ($h) = @_;
    $h = 4 if $h < 4;
    return $h - 2;
}

sub _pane_width {
    my ( $total, $which ) = @_;
    my $list_w = _list_width($total);
    my $preview_w = $total - $list_w - 1;
    return $which eq 'list' ? $list_w : $preview_w;
}

sub _canonical {
    my ($path) = @_;
    return '.' unless defined $path && length $path;
    $path =~ s{//+}{/}g;
    $path =~ s{/\.\z}{};
    return $path;
}

sub _fit {
    my ( $line, $width ) = @_;
    $line = '' unless defined $line;
    $line = substr( $line, 0, $width ) if length($line) > $width;
    return $line . ( ' ' x ( $width - length($line) ) );
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
