use strict;
use warnings;
use Test::More;
use PerlTea;

# A minimal stand-in model so the core contract can be exercised without a terminal.
{
    package PingModel;
    sub new    { bless { n => 0 }, shift }
    sub init   { return undef }
    sub update { my ($s, $msg) = @_; $s->{n}++; return ($s, undef) }
    sub view   { return "ping" }
}

my $p = PerlTea->new( model => PingModel->new );
isa_ok( $p, 'PerlTea', 'NewProgram returns a PerlTea' );
ok( defined $p->model, 'program holds its model' );
isa_ok( PerlTea->quit, 'PerlTea::Msg::Quit', 'quit() yields the Quit sentinel' );

# alt_screen option is recorded.
my $alt = PerlTea->new( model => PingModel->new, alt_screen => 1 );
ok( $alt->{alt_screen}, 'alt_screen option recorded' );

# new() without a model is a usage error.
eval { PerlTea->new() };
like( $@, qr/requires a 'model'/, 'new() without a model croaks' );

# run() is implemented as of gate G0: it runs the MVU loop and restores the terminal
# on every exit path. Driven with in-memory handles and an immediate end-of-input,
# it returns the (unchanged) model cleanly. The thorough teardown assertions live in
# t/g0-teardown.t.
{
    open my $in, '<', \( my $empty = '' ) or die "in: $!";
    my $out = '';
    open my $ofh, '>', \$out or die "out: $!";
    my $model = PingModel->new;
    my $final = PerlTea->new( model => $model, in => $in, out => $ofh )->run;
    is( $final, $model, 'run() returns the model and exits cleanly on EOF' );
}

done_testing;
