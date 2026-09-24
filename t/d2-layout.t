use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use PerlTea::App::GitDash;

# D2 — git dashboard layout + focus. The model renders a fixed-size multi-pane
# dashboard and switches visible focus on Tab. These tests drive the model
# directly so they stay deterministic regardless of the host git state.

my $model = PerlTea::App::GitDash->new( repo => '.' );

my $v = $model->view;
my @lines = split /\n/, $v, -1;
is( scalar(@lines), 24, 'default view height is 24' );
is( _vis_len( $lines[0] ), 80, 'default view width is 80' );

like( $v, qr/PerlTea GitDash/, 'header shows app name' );
like( $v, qr/Branches/,        'branches pane title present' );
like( $v, qr/Status/,          'status pane title present' );
like( $v, qr/Log/,             'log pane title present' );
like( $v, qr/Tab: next pane/,  'footer help present' );
like( $v, qr/Loading\.\.\./,   'panes show loading state before snapshot' );

# Tab moves focus and changes the rendered view.
my ($after_tab) = $model->update( { type => 'key', key => 'tab' } );
ok( defined $after_tab, 'update returns a model after Tab' );
my $view_after_tab = $after_tab->view;
isnt( $view_after_tab, $v, 'Tab changes the visible view' );

# Resizing reflows the layout.
my ($resized) = $after_tab->update( { type => 'resize', width => 100, height => 30 } );
my @rlines = split /\n/, $resized->view, -1;
is( scalar(@rlines), 30, 'resized view height is 30' );
is( _vis_len( $rlines[0] ), 100, 'resized view width is 100' );
isnt( $resized->view, $view_after_tab, 'resize changes the rendered view' );

# q returns the canonical quit sentinel.
my ($quit) = $model->update( { type => 'key', key => 'q' } );
isa_ok( $quit, 'PerlTea::Msg::Quit', 'q returns quit sentinel' );

# A snapshot message populates the dashboard data.
my $fixture_data = {
    branches => [
        { name => 'main', current => 1, sha => '4f3c2a1', upstream => 'origin/main', ahead => 1, behind => 0, gone => 0 },
    ],
    status => {
        branch   => 'main',
        upstream => 'origin/main',
        ahead    => 1,
        behind   => 0,
        clean    => 0,
        entries  => [ { x => 'M', y => ' ', path => 'lib/PerlTea.pm' } ],
    },
    log => [
        { short => '4f3c2a1', author => 'Scout', date => '2026-06-13', subject => 'Implement D2 layout' },
    ],
    errors => [],
};
my ($loaded) = $model->update( { type => 'snapshot', data => $fixture_data } );
my $loaded_view = $loaded->view;
like( $loaded_view, qr/On branch main/, 'status pane shows branch after snapshot' );
like( $loaded_view, qr/4f3c2a1/,        'log pane shows commit short hash' );
like( $loaded_view, qr/lib\/PerlTea\.pm/, 'status pane shows changed file' );

done_testing;

sub _vis_len {
    my ($s) = @_;
    $s =~ s/\e\[[0-9;]*[a-zA-Z]//g;
    return length $s;
}
