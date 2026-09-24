use strict;
use warnings;
use utf8;
use Encode qw(encode);
use Test::More;
use PerlTea::Input;

# H2 hardening: printable UTF-8 bytes must become one key event per character.
# A byte-at-a-time decoder turns these into mojibake and breaks real text input.

for my $case (
    [ '2-byte e-acute', 'é' ],
    [ '3-byte euro',    '€' ],
    [ '4-byte emoji',   "\x{1F600}" ],
) {
    my ( $name, $char ) = @$case;
    my $raw = encode( 'UTF-8', $char );
    my @msgs = PerlTea::Input->new->feed($raw);

    is( scalar @msgs, 1, "$name emits one message" );
    is_deeply(
        $msgs[0],
        { type => 'key', key => $char, rune => $char, raw => $raw },
        "$name decodes to one character key"
    );
}

{
    my $raw = encode( 'UTF-8', 'é' );
    my $dec = PerlTea::Input->new;

    my @lead = $dec->feed( substr( $raw, 0, 1 ) );
    is( scalar @lead, 0, 'split UTF-8 lead byte waits' );
    my @msgs = $dec->feed( substr( $raw, 1 ) );

    is( scalar @msgs, 1, 'split UTF-8 sequence completes one message' );
    is( $msgs[0]{key}, 'é', 'split UTF-8 sequence decodes intact' );
    is( $msgs[0]{raw}, $raw, 'split UTF-8 sequence preserves raw bytes' );
}

{
    my $raw = 'a' . encode( 'UTF-8', '€' ) . 'b';
    my @msgs = PerlTea::Input->new->feed($raw);

    is( scalar @msgs, 3, 'ASCII around UTF-8 remains three key events' );
    is( $msgs[0]{key}, 'a', 'leading ASCII key' );
    is( $msgs[1]{key}, '€', 'middle UTF-8 key' );
    is( $msgs[2]{key}, 'b', 'trailing ASCII key' );
}

{
    my $raw = "\e" . encode( 'UTF-8', 'é' );
    my @msgs = PerlTea::Input->new->feed($raw);

    is( scalar @msgs, 1, 'alt plus UTF-8 emits one message' );
    is( $msgs[0]{key}, 'alt+é', 'alt UTF-8 key is decoded before naming' );
    is( $msgs[0]{raw}, $raw, 'alt UTF-8 raw bytes preserved' );
}

{
    my $char = encode( 'UTF-8', 'é' );
    my $dec = PerlTea::Input->new;

    my @lead = $dec->feed( "\e" . substr( $char, 0, 1 ) );
    is( scalar @lead, 0, 'split alt UTF-8 waits without dropping bytes' );

    my @msgs = $dec->feed( substr( $char, 1 ) );
    is( scalar @msgs, 1, 'split alt UTF-8 completes one message' );
    is( $msgs[0]{key}, 'alt+é', 'split alt UTF-8 key decoded intact' );
}

done_testing;
