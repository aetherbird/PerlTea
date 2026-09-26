# PerlTea 🥤

A terminal-UI framework for **Perl** in the Elm Architecture (`model / update / view`). It ships with four sample apps: a markdown reader, a log explorer, a slides tool, and a git dashboard.

The framework stands on **core Perl only** with a `POSIX` termios for raw mode.  It is installable anywhere modern `perl` runs.

## The architecture

```perl
use PerlTea;

package Counter;
sub new    { bless { count => 0 }, shift }
sub update {
    my ($self, $msg) = @_;
    return (PerlTea->quit, undef) if $msg->{key} && $msg->{key} eq 'q';
    $self->{count}++ if $msg->{key} && $msg->{key} eq 'up';
    return ($self, undef);                 # (next_model, optional command)
}
sub view   { my ($self) = @_; "Counter: $self->{count}\n" }

package main;
PerlTea->new( model => Counter->new, alt_screen => 1 )->run;
```

- **model** is the state. **update** folds a message into the next state and returns
  an optional **command** (a coderef run asynchronously whose returned message
  re-enters `update`). **view** renders a string the diffing renderer paints with the
  minimal byte delta. Subscriptions feed timers/streams in as messages; the loop
  never blocks.

## Layout (CPAN distribution)

| Path | Role |
|------|------|
| `lib/PerlTea.pm` | Public core: the MVU runtime, `new`/`run`, the model contract. |
| `lib/PerlTea/Renderer.pm` | Diffing cell-buffer renderer (G1). |
| `lib/PerlTea/Input.pm` | Terminal input decoder — keys/mouse/paste (G2). |
| `lib/PerlTea/Style.pm` | Declarative styling — colors/borders/padding (G4). |
| `lib/PerlTea/Layout.pm` | Stacks / flexible sizing / nesting (G5). |
| `lib/PerlTea/Component/*.pm` | viewport, list, text-input, spinner, paginator, help (G6). |
| `lib/PerlTea/App/*.pm` | the four apps (Glow, Logexplorer, Slides, GitDash). |
| `cmd/<id>.pl` | One runnable demo per framework feature (`g0`…`d3`), the acceptance smoke tests. |
| `t/*.t` | Test::More tests (the gate test targets). |
| `testdata/` | Golden / snapshot fixtures (tracked). |

## Building & testing

```bash
perl Makefile.PL && make          # configure + build (core ExtUtils::MakeMaker)
prove -l t/                       # run the test suite
perl -Ilib -c lib/PerlTea.pm      # compile-check a module
perl -Ilib cmd/g0.pl              # run a gate demo
```

## Installation

```bash
perl Makefile.PL
make
make test
make install        # installs the PerlTea library + the 12 ptea-* commands
```

The same `PerlTea-0.02.tar.gz` produced by `make dist` is the CPAN upload candidate.

## License

Same terms as Perl itself (Artistic/GPL). See `LICENSE`.
