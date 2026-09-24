use strict;
use warnings;
use ExtUtils::MakeMaker;

# PerlTea — a from-scratch MVU (model/update/view) terminal-UI framework.
#
# Deliberately ZERO runtime dependencies: the framework stands on core Perl only
# (POSIX termios for raw mode; we emit ANSI escapes ourselves). The toolchain is
# the core ExtUtils::MakeMaker, so `perl Makefile.PL && make && make test` works
# offline with no CPAN installs.

WriteMakefile(
    NAME             => 'PerlTea',
    AUTHOR           => 'Scout of The Range',
    VERSION_FROM     => 'lib/PerlTea.pm',
    ABSTRACT         => 'An MVU (model/update/view) terminal UI framework in pure core Perl',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.016',

    # No runtime prerequisites — that is the whole point.
    PREREQ_PM        => {
        'POSIX'  => 0,   # core: termios, raw mode
        'Encode' => 0,   # core: UTF-8 handling
    },
    # Test-only prerequisites are all core.
    TEST_REQUIRES    => {
        'Test::More' => 0,
    },

    # Ship the app CLIs as installed commands.
    EXE_FILES        => [
        'bin/ptea-glow',
        'bin/ptea-log',
        'bin/ptea-slides',
        'bin/ptea-gitdash',
        'bin/ptea-rex',
        'bin/ptea-cpan',
        'bin/ptea-top',
        'bin/ptea-watch',
        'bin/ptea-svc',
        'bin/ptea-du',
        'bin/ptea-json',
        'bin/ptea-files',
    ],

    test => { TESTS => 't/*.t' },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources   => {
            repository => {
                type => 'git',
                url  => 'git@github.com:aetherbird/PerlTea.git',
                web  => 'https://github.com/aetherbird/PerlTea',
            },
        },
    },
    clean => { FILES => 'PerlTea-*' },
);
