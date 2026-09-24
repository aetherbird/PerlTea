package PerlTea::App::CPAN;

use strict;
use warnings;

use HTTP::Tiny ();
use JSON::PP ();
use PerlTea ();
use PerlTea::App::Glow ();
use PerlTea::Component::Spinner ();
use PerlTea::Component::TextInput ();

=head1 NAME

PerlTea::App::CPAN - MetaCPAN browser model for PerlTea

=head1 SYNOPSIS

    my $app = PerlTea::App::CPAN->new;
    PerlTea->new( model => $app, alt_screen => 1 )->run;

=head1 DESCRIPTION

C<PerlTea::App::CPAN> is a small MetaCPAN search browser. It focuses a query
input at startup; pressing C<Enter> searches and renders module names with their
abstracts. When C<PERLTEA_CPAN_FIXTURE> points at a JSON file, searches read that
file instead of the network so tests and acceptance gates are deterministic.

=cut

=head2 new

Construct the model. Options C<fixture>, C<width>, and C<height> are primarily
for tests; without C<fixture>, C<PERLTEA_CPAN_FIXTURE> is honored.

=cut

sub new {
    my ( $class, %args ) = @_;
    my $self = bless {
        fixture  => exists $args{fixture} ? $args{fixture} : $ENV{PERLTEA_CPAN_FIXTURE},
        width    => $args{width}  || 80,
        height   => $args{height} || 24,
        query    => '',
        results  => [],
        selected => 0,
        loading  => 0,
        detail   => 0,
        status   => 'Type a query and press Enter.',
        error    => '',
        install  => '',
        spinner  => PerlTea::Component::Spinner->new( label => 'working' ),
    }, $class;
    $self->_rebuild_input;
    return $self;
}

=head2 init

Return the initial command (none).

=cut

sub init { return undef }

=head2 subscriptions

Return a lightweight spinner tick subscription used while searches or installs
are running.

=cut

sub subscriptions {
    return [ { every => 0.12, msg => sub { return { type => 'tick' } } } ];
}

=head2 update

Fold a PerlTea message. C<q>/C<Ctrl-C> quit, C<Enter> searches, arrow keys move
through the result list, C<Enter> on a populated result list toggles detail view,
and C<i> runs C<cpanm> for the selected module asynchronously.

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

    if ( $type eq 'cpan_results' ) {
        $self->{loading} = 0;
        $self->{error}   = $msg->{error} || '';
        $self->{results} = $msg->{results} || [];
        $self->{selected} = 0;
        $self->{detail}   = 0;
        $self->{status} = $self->{error}
            ? 'Search failed.'
            : scalar( @{ $self->{results} } ) . ' result(s) for "' . $self->{query} . '".';
        return ( $self, undef );
    }

    if ( $type eq 'install_done' ) {
        $self->{loading} = 0;
        $self->{install} = $msg->{ok}
            ? 'Install finished: ' . ( $msg->{module} || '' )
            : 'Install failed: ' . ( $msg->{error} || $msg->{module} || 'unknown error' );
        return ( $self, undef );
    }

    if ( $type eq 'tick' ) {
        $self->{spinner}->tick if $self->{loading};
        return ( $self, undef );
    }

    my $key = $msg->{key} // '';
    return ( PerlTea->quit, undef ) if $key eq 'q' || $key eq 'ctrl+c';

    if ( $key eq 'enter' ) {
        if ( @{ $self->{results} } && !$self->{input_dirty} ) {
            $self->{detail} = !$self->{detail};
            return ( $self, undef );
        }
        $self->{query} = $self->{input}->value;
        $self->{loading} = 1;
        $self->{error}   = '';
        $self->{status}  = 'Searching for "' . $self->{query} . '".';
        $self->{input_dirty} = 0;
        return ( $self, $self->search_cmd( $self->{query} ) );
    }

    if ( $key eq 'down' || $key eq 'j' ) {
        $self->{selected}++ if $self->{selected} < @{ $self->{results} } - 1;
        return ( $self, undef );
    }
    if ( $key eq 'up' || $key eq 'k' ) {
        $self->{selected}-- if $self->{selected} > 0;
        return ( $self, undef );
    }
    if ( $key eq 'i' && @{ $self->{results} } ) {
        my $module = $self->{results}[ $self->{selected} ]{name};
        $self->{loading} = 1;
        $self->{install} = 'Installing ' . $module . '.';
        return ( $self, install_cmd($module) );
    }

    my $before = $self->{input}->value;
    $self->{input}->handle_msg($msg);
    $self->{input_dirty} = 1 if $self->{input}->value ne $before;
    return ( $self, undef );
}

=head2 view

Render the query input, status, results, optional detail pane, and help footer.

=cut

sub view {
    my ($self) = @_;
    my $w = $self->{width}  > 0 ? $self->{width}  : 80;
    my $h = $self->{height} > 5 ? $self->{height} : 6;

    my @out;
    push @out, "\e[1mCPAN:\e[22m " . $self->{input}->view;
    my $status = $self->{loading} ? $self->{spinner}->view . '  ' . $self->{status} : $self->{status};
    $status .= '  ' . $self->{install} if length $self->{install};
    push @out, _fit( $status, $w );
    push @out, _fit( $self->{error}, $w ) if length $self->{error};
    push @out, '-' x $w;

    my $footer_row = $h - 1;
    my $body_rows  = $footer_row - @out;
    $body_rows = 0 if $body_rows < 0;

    my @body = $self->{detail} ? $self->_detail_lines($body_rows) : $self->_result_lines($body_rows);
    push @out, @body;
    push @out, '' while @out < $footer_row;
    push @out, _fit( 'Enter: search/detail   up/down: select   i: install   q: quit', $w );
    return join "\n", @out;
}

=head2 search_cmd

Return an asynchronous command that searches either the fixture or MetaCPAN.

=cut

sub search_cmd {
    my ( $self, $query ) = @_;
    my $fixture = $self->{fixture};
    return sub {
        my ( $results, $error ) = search( $query, fixture => $fixture );
        return { type => 'cpan_results', results => $results, error => $error };
    };
}

=head2 install_cmd

Return an asynchronous command that invokes C<cpanm> for C<$module>. Tests may set
C<PERLTEA_CPANM_CMD> to replace the executable.

=cut

sub install_cmd {
    my ($module) = @_;
    return sub {
        my $cmd = $ENV{PERLTEA_CPANM_CMD} || 'cpanm';
        system $cmd, $module;
        my $ok = $? == 0 ? 1 : 0;
        return {
            type   => 'install_done',
            module => $module,
            ok     => $ok,
            error  => $ok ? '' : "$cmd exited " . ( $? >> 8 ),
        };
    };
}

=head2 search

    my ( $results, $error ) = PerlTea::App::CPAN::search('web', fixture => $path);

Run a search and return C<(\@results, undef)> or C<([], $error)>.

=cut

sub search {
    my ( $query, %opt ) = @_;
    my $json;
    if ( defined $opt{fixture} && length $opt{fixture} ) {
        $json = eval { read_fixture( $opt{fixture} ) };
        return ( [], _clean_json_error($@) ) if $@;
    }
    else {
        my $url = 'https://fastapi.metacpan.org/v1/module/_search?q=' . _url_escape($query || '')
            . '&fields=module.name,distribution,abstract,author,version,pod';
        my $res = HTTP::Tiny->new( timeout => 6 )->get($url);
        return ( [], $res->{reason} || 'HTTP search failed' ) unless $res->{success};
        $json = $res->{content};
    }

    my $data = eval { JSON::PP->new->utf8->decode($json) };
    return ( [], _clean_json_error($@) ) if $@;
    my @results = parse_search_response($data);
    return ( \@results, undef );
}

=head2 read_fixture

Read a UTF-8 JSON fixture file.

=cut

sub read_fixture {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot open $path: $!\n";
    local $/;
    my $json = <$fh>;
    close $fh;
    return $json;
}

=head2 parse_search_response

Parse the MetaCPAN C<_search> response into result hashes containing C<name>,
C<distribution>, C<abstract>, C<author>, C<version>, and C<pod>.

=cut

sub parse_search_response {
    my ($data) = @_;
    my $hits = $data->{hits}{hits} || [];
    my @results;
    for my $hit (@$hits) {
        my $src = $hit->{_source} || {};
        my $name = _module_name($src);
        next unless length $name;
        push @results, {
            name         => $name,
            distribution => $src->{distribution} || $name,
            abstract     => defined $src->{abstract} ? $src->{abstract} : '',
            author       => defined $src->{author}   ? $src->{author}   : '',
            version      => defined $src->{version}  ? $src->{version}  : '',
            pod          => defined $src->{pod}      ? $src->{pod}      : '',
        };
    }
    return @results;
}

sub _module_name {
    my ($src) = @_;
    return $src->{name} if defined $src->{name} && length $src->{name};
    if ( ref $src->{module} eq 'ARRAY' ) {
        for my $m ( @{ $src->{module} } ) {
            return $m->{name} if ref $m eq 'HASH' && defined $m->{name} && length $m->{name};
        }
    }
    return $src->{distribution} || '';
}

sub _result_lines {
    my ( $self, $rows ) = @_;
    my @lines;
    if ( $self->{loading} && !@{ $self->{results} } ) {
        push @lines, '.' x $self->{width} while @lines < $rows;
        return @lines;
    }
    for my $i ( 0 .. @{ $self->{results} } - 1 ) {
        last if @lines >= $rows;
        my $r = $self->{results}[$i];
        my $mark = $i == $self->{selected} ? '>' : ' ';
        push @lines, _fit( sprintf( '%s %s  %s', $mark, $r->{name}, $r->{abstract} ), $self->{width} );
        last if @lines >= $rows;
        push @lines, _fit( sprintf( '  %s %s  %s', $r->{author}, $r->{version}, $r->{distribution} ), $self->{width} );
    }
    push @lines, _fit( 'No results yet.', $self->{width} ) if !@lines && !@{ $self->{results} } && $rows > 0;
    push @lines, '' while @lines < $rows;
    return @lines;
}

sub _detail_lines {
    my ( $self, $rows ) = @_;
    return ('') x $rows unless @{ $self->{results} };
    my $r = $self->{results}[ $self->{selected} ];
    my $doc = "=head1 " . $r->{name} . "\n\n" . ( $r->{pod} || $r->{abstract} || 'No POD available.' ) . "\n";
    my $rendered = PerlTea::App::Glow::render( $doc, width => $self->{width} );
    my @lines = split /\n/, $rendered, -1;
    @lines = @lines[ 0 .. $rows - 1 ] if @lines > $rows;
    push @lines, '' while @lines < $rows;
    return @lines;
}

sub _rebuild_input {
    my ($self) = @_;
    my $iw = $self->{width} - 7;
    $iw = 1 if $iw < 1;
    my $value = $self->{input} ? $self->{input}->value : $self->{query};
    $self->{input} = PerlTea::Component::TextInput->new(
        width       => $iw,
        value       => $value,
        focus       => 1,
        placeholder => 'search modules',
    );
    return;
}

sub _fit {
    my ( $line, $width ) = @_;
    $line = '' unless defined $line;
    $line =~ s/\n/ /g;
    $line = substr( $line, 0, $width ) if length($line) > $width;
    return $line . ( ' ' x ( $width - length($line) ) );
}

sub _url_escape {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/([^A-Za-z0-9_.~-])/sprintf '%%%02X', ord($1)/eg;
    return $s;
}

sub _clean_json_error {
    my ($err) = @_;
    $err ||= 'invalid JSON';
    $err =~ s/\s+at .* line \d+.*//s;
    $err =~ s/\s+\z//;
    return $err;
}

1;

__END__

=head1 AUTHOR

PerlTea contributors

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
