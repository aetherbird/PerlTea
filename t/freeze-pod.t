#!/usr/bin/env perl
# FREEZE GATE — POD coverage for every public sub in the framework.
#
# This test walks every .pm file under lib/, finds each package's public subs
# (names not starting with underscore), and insists that each one has a POD
# heading (=head1/2/3/4 or =item) that mentions the sub name. It is implemented
# with core Pod::Simple so there is no CPAN Test::Pod::Coverage dependency.

use strict;
use warnings;
use Test::More;
use File::Find ();
use Pod::Simple::SimpleTree ();

my @pm;
File::Find::find(
    {
        wanted => sub {
            push @pm, $File::Find::name
                if -f $_ && /\.pm\z/;
        },
        no_chdir => 1,
    },
    'lib'
);

my @missing;
for my $file (@pm) {
    my %subs_for = _public_subs($file);
    next unless keys %subs_for;

    my @headings = _pod_headings($file);
    my %head = map { $_ => 1 } @headings;

    for my $pkg ( sort keys %subs_for ) {
        for my $sub ( sort @{ $subs_for{$pkg} } ) {
            push @missing, "$pkg\::$sub"
                unless $head{$sub};
        }
    }
}

ok( !@missing, 'every public sub is documented in POD' );
diag("Missing POD for: $_") for @missing;

done_testing();

# Gather package => [public sub names] from a Perl module, ignoring POD examples.
sub _public_subs {
    my ($file) = @_;
    open my $fh, '<', $file or die "$file: $!";
    my @lines = <$fh>;
    close $fh;

    my @code;
    my $in_pod = 0;
    for my $line (@lines) {
        if ( $line =~ /^=[a-zA-Z]/ ) { $in_pod = 1; next; }
        if ( $line =~ /^=cut\b/ )    { $in_pod = 0; next; }
        next if $in_pod;
        last if $line =~ /^__(END|DATA)__\b/;
        push @code, $line;
    }

    my (%subs_for, $pkg);
    for my $line (@code) {
        if ( $line =~ /^\s*package\s+([A-Za-z0-9_:]+)\s*;/ ) {
            $pkg = $1;
            next;
        }
        next unless defined $pkg;
        if ( $line =~ /^\s*sub\s+([a-zA-Z_]\w*)\s*[\{\(]/ ) {
            my $name = $1;
            next if $name =~ /^_/;    # private
            push @{ $subs_for{$pkg} }, $name;
        }
    }
    return %subs_for;
}

# Extract all heading/item text from the POD in a file.
sub _pod_headings {
    my ($file) = @_;
    my $parser = Pod::Simple::SimpleTree->new;
    $parser->parse_file($file);
    my $tree = $parser->root;
    return () unless $tree;
    return _extract_text_headings($tree);
}

sub _extract_text_headings {
    my ($node) = @_;
    return () unless ref $node eq 'ARRAY';

    my ( $type, undef, @children ) = @$node;
    my @out;

    if ( $type =~ /^head[1-4]\z/ || $type eq 'item' ) {
        my $text = _flatten_text($node);
        # Exact sub-name match is enough; our POD uses the bare name in =head2.
        push @out, $text if defined $text && $text ne '';
    }

    for my $child (@children) {
        push @out, _extract_text_headings($child);
    }
    return @out;
}

sub _flatten_text {
    my ($node) = @_;
    return $node unless ref $node eq 'ARRAY';

    my ( $type, undef, @children ) = @$node;
    return join '', map { _flatten_text($_) } @children;
}
