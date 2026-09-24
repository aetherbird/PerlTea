package PerlTea::App::Du;

use strict;
use warnings;

use PerlTea ();
use PerlTea::Component::List ();

=head1 NAME

PerlTea::App::Du - an ncdu-style disk-usage explorer for PerlTea

=head1 SYNOPSIS

    use PerlTea::App::Du;
    my $app = PerlTea::App::Du->new( path => '/var/log' );
    PerlTea->new( model => $app, alt_screen => 1 )->run;

=head1 DESCRIPTION

C<PerlTea::App::Du> scans a directory tree, aggregates the size of each entry
(recursively for directories), and presents the immediate children sorted
largest-first.  C<Enter> (or C<l>/Right) descends into the selected directory;
C<u> (or C<h>/Left/Backspace) returns to the parent.  C<q> quits.

The scan is deterministic and depends only on the filesystem, so the gate can
build a known tree and drive the real CLI against it.

=cut

=head2 new

    my $app = PerlTea::App::Du->new( path => $dir );
    my $app = PerlTea::App::Du->new( path => $dir, width => 80, height => 24 );

Construct the model rooted at C<path> (default C<.>).  Width and height are
corrected by the startup resize message.

=cut

sub new {
    my ( $class, %args ) = @_;

    my $root = defined $args{path} ? $args{path} : '.';

    my $self = bless {
        root     => $root,
        cwd      => $root,
        width    => $args{width}  || 80,
        height   => $args{height} || 24,
        entries  => [],
        selected => 0,
        error    => '',
        stack    => [],    # breadcrumb: { dir, selected } per level descended
    }, $class;

    $self->_load;
    return $self;
}

=head2 init

Return the initial command (none); the constructor scans the root tree
synchronously so the first frame is populated.

=cut

sub init { return undef }

=head2 update

    my ( $model, $cmd ) = $app->update($msg);

Fold a PerlTea message.  C<q>/C<Ctrl-C> quit; C<up>/C<k> and C<down>/C<j> move
the selection; C<Enter>/C<l>/Right descends into the selected directory;
C<u>/C<h>/Left/Backspace returns to the parent directory.

=cut

sub update {
    my ( $self, $msg ) = @_;
    my $type = $msg->{type} // '';

    if ( $type eq 'resize' ) {
        $self->{width}  = $msg->{width}  if $msg->{width};
        $self->{height} = $msg->{height} if $msg->{height};
        return ( $self, undef );
    }

    my $key = $msg->{key} // '';
    return ( PerlTea->quit, undef ) if $key eq 'q' || $key eq 'ctrl+c';

    if ( $key eq 'up' || $key eq 'k' ) {
        $self->{selected}-- if $self->{selected} > 0;
        return ( $self, undef );
    }
    if ( $key eq 'down' || $key eq 'j' ) {
        $self->{selected}++ if $self->{selected} < @{ $self->{entries} } - 1;
        return ( $self, undef );
    }

    if ( $key eq 'enter' || $key eq 'right' || $key eq 'l' ) {
        $self->_descend;
        return ( $self, undef );
    }

    if (   $key eq 'u'
        || $key eq 'h'
        || $key eq 'left'
        || $key eq 'backspace' )
    {
        $self->_ascend;
        return ( $self, undef );
    }

    return ( $self, undef );
}

=head2 view

Render a header (current path, total size, entry count), the largest-first list
of entries, and a help footer.

=cut

sub view {
    my ($self) = @_;
    my $w = $self->{width}  > 0 ? $self->{width}  : 80;
    my $h = $self->{height} > 3 ? $self->{height} : 4;

    my @out;
    my $total = 0;
    $total += $_->{size} for @{ $self->{entries} };
    my $header = sprintf(
        'du: %s  (%s, %d entries)',
        $self->{cwd}, format_size($total), scalar @{ $self->{entries} },
    );
    push @out, _fit( $header, $w );
    push @out, _fit( 'Error: ' . $self->{error}, $w ) if length $self->{error};

    my $footer = 'q: quit   up/down: select   enter/l: open   u/h: up';
    my $used   = @out + 1;    # +1 for the footer line
    my $list_h = $h - $used;
    $list_h = 0 if $list_h < 0;

    if ( $list_h > 0 ) {
        my @items =
            map { _format_entry( $_, $w - 2 ) } @{ $self->{entries} };
        @items = ('(empty directory)') unless @items;
        my $list = PerlTea::Component::List->new(
            items    => \@items,
            width    => $w,
            height   => $list_h,
            selected => $self->{selected},
            focus    => 1,
        );
        push @out, split /\n/, $list->view;
    }

    push @out, '' while @out < $h - 1;
    push @out, _fit( $footer, $w );

    return join "\n", @out;
}

# ── pure scan engine (unit tested directly) ──────────────────────────────────

=head2 entry_size

    my $bytes = PerlTea::App::Du::entry_size($path);

Return the aggregate size of C<$path> in bytes.  For a regular file this is its
own size; for a directory it is the recursive sum of its contents.  Symlinks are
never followed (their own link size is counted), so the scan cannot loop.

=cut

sub entry_size {
    my ($path) = @_;
    my @st = lstat $path;
    return 0 unless @st;

    if ( -l _ ) {
        return $st[7] || 0;    # the symlink itself, never its target
    }
    if ( -d _ ) {
        my $total = 0;
        if ( opendir my $dh, $path ) {
            my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
            closedir $dh;
            $total += entry_size("$path/$_") for @names;
        }
        return $total;
    }
    return $st[7] || 0;
}

=head2 scan

    my $entries = PerlTea::App::Du::scan($dir);

Scan the immediate children of C<$dir> and return an arrayref of entry hashes
C<{ name, path, is_dir, size }>, sorted largest-first (size descending, then
name ascending as a stable tie-breaker).  An unreadable directory yields an
empty list.

=cut

sub scan {
    my ($dir) = @_;

    my @entries;
    if ( opendir my $dh, $dir ) {
        my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        for my $name (@names) {
            my $path   = "$dir/$name";
            my $is_dir = ( -d $path && !-l $path ) ? 1 : 0;
            push @entries, {
                name   => $name,
                path   => $path,
                is_dir => $is_dir,
                size   => entry_size($path),
            };
        }
    }

    @entries = sort {
        $b->{size} <=> $a->{size}
            || $a->{name} cmp $b->{name}
    } @entries;

    return \@entries;
}

=head2 format_size

    my $human = PerlTea::App::Du::format_size($bytes);

Format a byte count as a short human-readable string: bytes as C<512B>, larger
sizes with one decimal place and a binary (1024) unit suffix, e.g. C<1.0M>.

=cut

sub format_size {
    my ($bytes) = @_;
    $bytes = 0 unless defined $bytes;

    my @units = qw(B K M G T P);
    my $u     = 0;
    my $size  = $bytes;
    while ( $size >= 1024 && $u < $#units ) {
        $size /= 1024;
        $u++;
    }
    return sprintf( '%d%s',   $size, $units[$u] ) if $u == 0;
    return sprintf( '%.1f%s', $size, $units[$u] );
}

# ── internals ────────────────────────────────────────────────────────────────

sub _load {
    my ($self) = @_;

    $self->{selected} = 0;

    if ( !-d $self->{cwd} ) {
        $self->{entries} = [];
        $self->{error}   = "not a directory: $self->{cwd}";
        return;
    }
    if ( !opendir my $probe, $self->{cwd} ) {
        $self->{entries} = [];
        $self->{error}   = "cannot open $self->{cwd}: $!";
        return;
    }
    else {
        closedir $probe;
    }

    $self->{entries} = scan( $self->{cwd} );
    $self->{error}   = '';
    return;
}

# Descend into the selected entry if it is a directory.
sub _descend {
    my ($self) = @_;
    return unless @{ $self->{entries} };
    my $entry = $self->{entries}[ $self->{selected} ];
    return unless $entry && $entry->{is_dir};

    push @{ $self->{stack} },
        { dir => $self->{cwd}, selected => $self->{selected} };
    $self->{cwd} = $entry->{path};
    $self->_load;    # resets selection to the largest child
    return;
}

# Return to the parent directory we descended from (if any).
sub _ascend {
    my ($self) = @_;
    return unless @{ $self->{stack} };
    my $prev = pop @{ $self->{stack} };
    $self->{cwd} = $prev->{dir};
    $self->_load;
    my $last = @{ $self->{entries} } - 1;
    my $sel  = $prev->{selected};
    $sel = 0     if $sel < 0;
    $sel = $last if $last >= 0 && $sel > $last;
    $self->{selected} = $sel;
    return;
}

sub _format_entry {
    my ( $entry, $width ) = @_;
    my $size = format_size( $entry->{size} );
    my $name = $entry->{name} . ( $entry->{is_dir} ? '/' : '' );
    my $line = sprintf( '%8s  %s', $size, $name );
    $line = substr( $line, 0, $width ) if length($line) > $width;
    return $line;
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
