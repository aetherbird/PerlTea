package PerlTea::App::GitDash;

use strict;
use warnings;

use PerlTea::Component::List;
use PerlTea::Component::Viewport;
use PerlTea::Layout;
use PerlTea::Style;
use PerlTea::Width ();
use PerlTea;

=head1 NAME

PerlTea::App::GitDash - git data loading and parsers for the dashboard app

=head1 SYNOPSIS

    use PerlTea::App::GitDash;

    my $data = PerlTea::App::GitDash::snapshot('.');
    my $branches = PerlTea::App::GitDash::parse_branches($branch_output);

=head1 DESCRIPTION

C<PerlTea::App::GitDash> is the shared data layer for the D-series git
dashboard demos. D1 exposes pure parsers for captured C<git branch>,
C<git status>, and C<git log> output, plus small core-Perl helpers that run the
matching git commands. Later gates build the interactive layout and async
refresh behaviour over this stable shape.

=cut

=head2 git_commands

    my $commands = PerlTea::App::GitDash::git_commands($repo);

Return the command vectors used by the dashboard. The C<branches>, C<status>,
and C<log> entries are arrayrefs suitable for C<open '-|'> or PerlTea commands.

=cut

sub git_commands {
    my ($repo) = @_;
    $repo = '.' unless defined $repo && length $repo;

    return {
        branches => [ 'git', '-C', $repo, 'branch', '--list', '--no-color', '-vv' ],
        status   => [ 'git', '-C', $repo, 'status', '--porcelain=v1', '-b' ],
        log      => [
            'git', '-C', $repo, 'log',
            '--date=short',
            '--decorate=short',
            '--pretty=format:%H%x09%h%x09%an%x09%ad%x09%D%x09%s',
            '-n', '50',
        ],
    };
}

=head2 run_git

    my ($output, $error) = PerlTea::App::GitDash::run_git($repo, 'status');

Run one dashboard git command and return C<($stdout, undef)> on success or
C<('', $message)> on failure. C<$kind> must be C<branches>, C<status>, or
C<log>. The function uses only core Perl and list-form C<open>, so repository
paths are not interpreted by a shell.

=cut

sub run_git {
    my ( $repo, $kind ) = @_;
    my $commands = git_commands($repo);
    return ( '', "unknown git command kind: $kind" ) unless exists $commands->{$kind};

    my @cmd = @{ $commands->{$kind} };
    open my $fh, '-|', @cmd
        or return ( '', "cannot run @cmd: $!" );

    local $/;
    my $out = <$fh>;
    $out = '' unless defined $out;
    my $ok = close $fh;
    return ( $out, undef ) if $ok;

    my $exit = $? >> 8;
    return ( '', "git command failed ($exit): @cmd" );
}

=head2 snapshot

    my $data = PerlTea::App::GitDash::snapshot($repo);

Run all D1 git commands for C<$repo> and return a hashref with C<branches>,
C<status>, C<log>, and C<errors> keys. Command failures are collected in
C<errors> while successful commands are parsed normally.

=cut

sub snapshot {
    my ($repo) = @_;

    my %data = (
        branches => [],
        status   => parse_status(''),
        log      => [],
        errors   => [],
    );

    for my $kind (qw(branches status log)) {
        my ( $out, $err ) = run_git( $repo, $kind );
        if ( defined $err ) {
            push @{ $data{errors} }, { kind => $kind, error => $err };
            next;
        }

        if ( $kind eq 'branches' ) {
            $data{branches} = parse_branches($out);
        }
        elsif ( $kind eq 'status' ) {
            $data{status} = parse_status($out);
        }
        else {
            $data{log} = parse_log($out);
        }
    }

    return \%data;
}

=head2 parse_branches

    my $branches = PerlTea::App::GitDash::parse_branches($text);

Parse C<git branch --list --no-color -vv> output. Returns an arrayref of
hashrefs with C<name>, C<current>, C<sha>, C<upstream>, C<ahead>, C<behind>,
C<gone>, C<remote>, and C<subject> fields.

=cut

sub parse_branches {
    my ($text) = @_;
    $text = '' unless defined $text;

    my @branches;
    for my $line ( split /\n/, $text ) {
        next unless length $line;
        next unless $line =~ /^([* ])\s+(.+?)\s+([0-9a-fA-F]{4,40})(?:\s+\[([^\]]+)\])?\s*(.*)\z/;

        my ( $mark, $name, $sha, $tracking, $subject ) = ( $1, $2, lc($3), $4, $5 );
        my ( $upstream, $ahead, $behind, $gone ) = _parse_tracking($tracking);
        push @branches, {
            name     => $name,
            current  => $mark eq '*' ? 1 : 0,
            sha      => $sha,
            upstream => $upstream,
            ahead    => $ahead,
            behind   => $behind,
            gone     => $gone,
            remote   => $name =~ m{\Aremotes/} ? 1 : 0,
            subject  => $subject,
        };
    }

    return \@branches;
}

=head2 parse_status

    my $status = PerlTea::App::GitDash::parse_status($text);

Parse C<git status --porcelain=v1 -b> output. Returns a hashref containing the
current C<branch>, optional C<upstream>, C<ahead>/C<behind> counts, C<clean>,
and an C<entries> array. Each entry has C<x>, C<y>, C<path>, C<old_path>,
C<staged>, C<unstaged>, C<untracked>, and C<conflict> fields.

=cut

sub parse_status {
    my ($text) = @_;
    $text = '' unless defined $text;

    my $status = {
        branch   => undef,
        upstream => undef,
        ahead    => 0,
        behind   => 0,
        entries  => [],
        clean    => 1,
    };

    for my $line ( split /\n/, $text ) {
        next unless length $line;
        if ( $line =~ /^\#\#\s+(.*)\z/ ) {
            _parse_status_header( $status, $1 );
            next;
        }

        next unless length($line) >= 3;
        my $x    = substr( $line, 0, 1 );
        my $y    = substr( $line, 1, 1 );
        my $path = substr( $line, 3 );

        my $old_path;
        if ( $x eq 'R' || $x eq 'C' ) {
            ( $old_path, $path ) = split /\s+->\s+/, $path, 2;
        }

        push @{ $status->{entries} }, {
            x         => $x,
            y         => $y,
            path      => $path,
            old_path  => $old_path,
            staged    => ( $x ne ' ' && $x ne '?' ) ? 1 : 0,
            unstaged  => ( $y ne ' ' && $y ne '?' ) ? 1 : 0,
            untracked => ( $x eq '?' && $y eq '?' ) ? 1 : 0,
            conflict  => _is_conflict_status( $x, $y ),
        };
    }

    $status->{clean} = @{ $status->{entries} } ? 0 : 1;
    return $status;
}

=head2 parse_log

    my $commits = PerlTea::App::GitDash::parse_log($text);

Parse the tab-separated C<git log> format emitted by L</git_commands>. Returns
an arrayref of commits with C<hash>, C<short>, C<author>, C<date>, C<refs>, and
C<subject> fields.

=cut

sub parse_log {
    my ($text) = @_;
    $text = '' unless defined $text;

    my @commits;
    for my $line ( split /\n/, $text ) {
        next unless length $line;
        my ( $hash, $short, $author, $date, $refs, $subject ) =
            split /\t/, $line, 6;
        next unless defined $subject && defined $hash && $hash =~ /\A[0-9a-fA-F]{7,40}\z/;

        push @commits, {
            hash    => lc($hash),
            short   => $short,
            author  => $author,
            date    => $date,
            refs    => _parse_refs($refs),
            subject => $subject,
        };
    }

    return \@commits;
}

sub _parse_tracking {
    my ($tracking) = @_;
    return ( undef, 0, 0, 0 ) unless defined $tracking && length $tracking;

    my ( $upstream, $state ) = split /:\s*/, $tracking, 2;
    $upstream = undef if defined $upstream && $upstream eq 'gone';

    my ( $ahead, $behind, $gone ) = ( 0, 0, 0 );
    my $scan = defined $state ? $state : $tracking;
    $ahead  = $1 if $scan =~ /\bahead\s+(\d+)/;
    $behind = $1 if $scan =~ /\bbehind\s+(\d+)/;
    $gone   = 1  if $scan =~ /\bgone\b/ || $tracking eq 'gone';

    return ( $upstream, $ahead, $behind, $gone );
}

sub _parse_status_header {
    my ( $status, $header ) = @_;

    if ( $header =~ /^No commits yet on (.+)\z/ ) {
        $status->{branch} = $1;
        return;
    }
    if ( $header =~ /^HEAD \(no branch\)\z/ ) {
        $status->{branch} = 'HEAD';
        return;
    }

    my ( $left, $state ) = split /\s+\[/, $header, 2;
    $state =~ s/\]\z// if defined $state;

    if ( $left =~ /^(.+?)\.\.\.(.+)\z/ ) {
        $status->{branch}   = $1;
        $status->{upstream} = $2;
    }
    else {
        $status->{branch} = $left;
    }

    if ( defined $state ) {
        $status->{ahead}  = $1 if $state =~ /\bahead\s+(\d+)/;
        $status->{behind} = $1 if $state =~ /\bbehind\s+(\d+)/;
    }
    return;
}

sub _is_conflict_status {
    my ( $x, $y ) = @_;
    return 1 if $x eq 'U' || $y eq 'U';
    return 1 if ( $x eq 'A' && $y eq 'A' );
    return 1 if ( $x eq 'D' && $y eq 'D' );
    return 1 if ( $x eq 'A' && $y eq 'D' );
    return 1 if ( $x eq 'D' && $y eq 'A' );
    return 0;
}

sub _parse_refs {
    my ($refs) = @_;
    return [] unless defined $refs && length $refs;

    my @refs;
    for my $ref ( split /,\s*/, $refs ) {
        $ref =~ s/\A\s+|\s+\z//g;
        $ref =~ s/\AHEAD ->\s*//;
        push @refs, $ref if length $ref;
    }
    return \@refs;
}

=head2 new

    my $dash = PerlTea::App::GitDash->new(repo => '.');

Create an interactive dashboard model for the D-series gates. The model loads
its data asynchronously via C<init>/C<update> and renders a multi-pane layout
with switchable focus.

=cut

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        repo          => defined $args{repo} ? $args{repo} : '.',
        width         => $args{width}  || 80,
        height        => $args{height} || 24,
        focus         => $args{focus} || 0,
        data          => undef,
        loading       => 1,
        refreshing    => 0,
        refreshes     => 0,
        color_profile => $args{color_profile} || _detect_profile(),
    };
    bless $self, $class;
    return $self;
}

sub _detect_profile {
    return '16' if ( $ENV{PERLTEA_FORCE_COLORS} // '' ) eq '16';
    my $ct = lc( $ENV{COLORTERM} // '' );
    return 'truecolor' if $ct eq 'truecolor' || $ct eq '24bit';
    my $term = lc( $ENV{TERM} // '' );
    return '256'     if $term =~ /256/;
    return 'truecolor' if $term =~ /truecolor|24bit/;
    return '16';
}

=head2 init

Return an initial command that loads the dashboard data asynchronously. The
command returns a C<< { type => 'snapshot', data => ... } >> message that the
model folds in C<update>.

=cut

sub init {
    my ($self) = @_;
    return $self->refresh_cmd;
}

=head2 refresh_cmd

    my $cmd = $dash->refresh_cmd;

Return a PerlTea command coderef that runs all dashboard git commands and
returns a C<< { type => 'snapshot', data => ... } >> message. The coderef is run
asynchronously by the runtime (forked off the event loop), so the git calls
never block input. When C<PERLTEA_GATE_SLOWGIT> is set the git work is delayed
deliberately to prove the loop stays responsive while a slow refresh is in
flight; because the delay happens inside the command child it does not freeze
the UI.

=cut

sub refresh_cmd {
    my ($self) = @_;
    my $repo = $self->{repo};
    return sub {
        _gate_slow_delay();
        return { type => 'snapshot', data => snapshot($repo) };
    };
}

# Simulate a slow git call ONLY inside the forked command child (never the main
# loop). Used by the test harness to prove the UI does not freeze during a git
# call.
sub _gate_slow_delay {
    return unless $ENV{PERLTEA_GATE_SLOWGIT};
    select( undef, undef, undef, 2.0 );
    return;
}

=head2 update

    my ($next, $cmd) = $dash->update($msg);

Fold a PerlTea message into the next model state. Handles the async snapshot
result, terminal resize, Tab focus cycling, and C<q> to quit.

=cut

sub update {
    my ( $self, $msg ) = @_;

    if ( $msg->{type} eq 'snapshot' ) {
        $self->{data}       = $msg->{data};
        $self->{loading}    = 0;
        $self->{refreshing} = 0;
        $self->{refreshes}++;
        return ( $self, undef );
    }

    if ( $msg->{type} eq 'resize' ) {
        $self->{width}  = $msg->{width}  || 80;
        $self->{height} = $msg->{height} || 24;
        return ( $self, undef );
    }

    if ( $msg->{type} eq 'key' ) {
        my $key = $msg->{key} // '';
        return ( PerlTea->quit, undef ) if $key eq 'q' || $key eq 'Q';

        if ( $key eq 'tab' ) {
            $self->{focus} = ( $self->{focus} + 1 ) % 3;
            return ( $self, undef );
        }

        # 'r' kicks off an async refresh: update returns immediately with a
        # command, and the (possibly slow) git work runs off the loop.
        if ( $key eq 'r' || $key eq 'R' ) {
            $self->{refreshing} = 1;
            return ( $self, $self->refresh_cmd );
        }
    }

    return ( $self, undef );
}

=head2 view

    my $rendered = $dash->view;

Render the dashboard. The view is always exactly C<width> x C<height>: a
header, three side-by-side panes (branches, status, log), and a help footer.
The focused pane is drawn with a double border and a reversed title so focus
changes are visible.

=cut

sub view {
    my ($self) = @_;

    my $w = $self->{width};
    my $h = $self->{height};
    my $body_h = $h - 2;
    $body_h = 3 if $body_h < 3;

    my @pane_titles = ( 'Branches', 'Status', 'Log' );
    my @pane_lines = (
        [ $self->_branches_lines ],
        [ $self->_status_lines ],
        [ $self->_log_lines ],
    );

    my @pane_w = _flex_alloc( $w, [ 1, 1, 1 ] );
    my @panes;
    for my $i ( 0 .. 2 ) {
        push @panes,
            $self->_render_pane(
            $pane_titles[$i],
            $pane_lines[$i],
            $pane_w[$i],
            $body_h,
            $self->{focus} == $i
            );
    }

    my @rows;
    push @rows, $self->_render_header;

    my @pcols = map { [ split /\n/, $_, -1 ] } @panes;
    for my $r ( 0 .. $body_h - 1 ) {
        my $line = '';
        $line .= $pcols[$_][$r] // '' for 0 .. 2;
        push @rows, _fit_line( $line, $w );
    }

    push @rows, $self->_render_footer;

    return join "\n", @rows;
}

sub _render_header {
    my ($self) = @_;
    my $repo   = $self->{repo};
    my $branch = '...';
    if ( $self->{data} && $self->{data}{status} && $self->{data}{status}{branch} ) {
        $branch = $self->{data}{status}{branch};
    }
    my $text = " PerlTea GitDash: $repo  ($branch) ";
    my $style = PerlTea::Style->new(
        width         => $self->{width},
        height        => 1,
        reverse       => 1,
        align         => 'left',
        color_profile => $self->{color_profile},
    );
    return $style->render($text);
}

sub _render_footer {
    my ($self) = @_;
    my $text =
        $self->{refreshing}
        ? 'Refreshing...  q: quit'
        : 'Tab: next pane  r: refresh  q: quit';
    my $style = PerlTea::Style->new(
        width         => $self->{width},
        height        => 1,
        align         => 'center',
        color_profile => $self->{color_profile},
    );
    return $style->render($text);
}

sub _render_pane {
    my ( $self, $title, $lines, $w, $h, $focus ) = @_;
    return ( " " x $w ) x $h if $w < 4 || $h < 3;

    my $cw = $w - 2;
    my $ch = $h - 2;

    my $title_line = $focus ? "\e[7m $title \e[27m" : " $title ";
    my $vp = PerlTea::Component::Viewport->new(
        width   => $cw,
        height  => $ch,
        content => join( "\n", $title_line, @$lines ),
    );

    my $style = PerlTea::Style->new(
        border        => $focus ? 'double' : 'single',
        width         => $cw,
        height        => $ch,
        align         => 'left',
        color_profile => $self->{color_profile},
    );
    return $style->render( $vp->view );
}

sub _branches_lines {
    my ($self) = @_;
    return ('Loading...') if $self->{loading} || !$self->{data};
    my $branches = $self->{data}{branches} // [];
    return ('No branches') unless @$branches;

    my @out;
    for my $b (@$branches) {
        my $line = ( $b->{current} ? '* ' : '  ' ) . $b->{name};
        if ( $b->{upstream} ) {
            $line .= " [$b->{upstream}]";
            $line .= ' gone' if $b->{gone};
            $line .= " +$b->{ahead}" if $b->{ahead};
            $line .= " -$b->{behind}" if $b->{behind};
        }
        push @out, $line;
    }
    return @out;
}

sub _status_lines {
    my ($self) = @_;
    return ('Loading...') if $self->{loading} || !$self->{data};

    if ( $self->{data}{errors} ) {
        my @e = grep { $_->{kind} eq 'status' } @{ $self->{data}{errors} };
        return ("Error: $e[0]{error}") if @e;
    }

    my $s = $self->{data}{status} // {};
    my $line = 'On branch ' . ( $s->{branch} // 'unknown' );
    if ( $s->{upstream} ) {
        $line .= " [$s->{upstream}]";
        $line .= " +$s->{ahead}" if $s->{ahead};
        $line .= " -$s->{behind}" if $s->{behind};
    }
    my @out = ($line);

    if ( $s->{clean} ) {
        push @out, 'working tree clean';
    }
    else {
        for my $e ( @{ $s->{entries} // [] } ) {
            push @out, "$e->{x}$e->{y} $e->{path}";
        }
    }
    return @out;
}

sub _log_lines {
    my ($self) = @_;
    return ('Loading...') if $self->{loading} || !$self->{data};
    my $commits = $self->{data}{log} // [];
    return ('No commits') unless @$commits;

    my @out;
    for my $c (@$commits) {
        push @out, "$c->{short} $c->{author} $c->{date} $c->{subject}";
    }
    return @out;
}

sub _flex_alloc {
    my ( $total, $weights ) = @_;
    my $sum = 0;
    $sum += $_ for @$weights;
    $sum = 1 if $sum <= 0;

    my @out;
    my $used = 0;
    for my $i ( 0 .. $#$weights - 1 ) {
        my $w = int( $total * $weights->[$i] / $sum );
        $w = 0 if $w < 0;
        push @out, $w;
        $used += $w;
    }
    push @out, $total - $used;
    return @out;
}

sub _fit_line {
    my ( $line, $width ) = @_;
    my $len = _visible_length($line);
    return $line . ( ' ' x ( $width - $len ) ) if $len < $width;
    return $line;
}

sub _visible_length {
    my ($s) = @_;
    return PerlTea::Width::display_width($s);
}

1;
