<?php
namespace Modules\HarborPine\Services;

/**
 * Deterministic PRNG (mulberry32) with helpers. A day's events are planned from
 * Rng::forKey($seed, 'YYYY-MM-DD'), so any day can be (re)planned identically and independently.
 */
class Rng
{
    private int $state;

    public function __construct( int $seed )
    {
        $this->state = $seed & 0xFFFFFFFF;
    }

    public static function forKey( int $seed, string $key ): self
    {
        return new self( ( $seed ^ crc32( $key ) ) & 0xFFFFFFFF );
    }

    public function next(): float
    {
        $this->state = ( $this->state + 0x6D2B79F5 ) & 0xFFFFFFFF;
        $t = $this->state;
        $t = $this->imul( $t ^ ( $t >> 15 ), $t | 1 );
        $t ^= ( $t + $this->imul( $t ^ ( $t >> 7 ), $t | 61 ) ) & 0xFFFFFFFF;
        $t &= 0xFFFFFFFF;

        return ( ( $t ^ ( $t >> 14 ) ) & 0xFFFFFFFF ) / 4294967296;
    }

    private function imul( int $a, int $b ): int
    {
        $a &= 0xFFFFFFFF;
        $b &= 0xFFFFFFFF;
        $lo = ( ( $a & 0xFFFF ) * $b ) & 0xFFFFFFFF;
        $hi = ( ( ( $a >> 16 ) * $b ) & 0xFFFF ) << 16;

        return ( $lo + $hi ) & 0xFFFFFFFF;
    }

    public function int( int $min, int $max ): int
    {
        return $min + (int) floor( $this->next() * ( $max - $min + 1 ) );
    }

    public function chance( float $p ): bool
    {
        return $this->next() < $p;
    }

    public function pick( array $items )
    {
        return $items[ (int) floor( $this->next() * count( $items ) ) ];
    }

    /** @param array<array{0:mixed,1:float}> $pairs [value, weight] */
    public function weighted( array $pairs )
    {
        $total = array_sum( array_column( $pairs, 1 ) );
        $r = $this->next() * $total;
        foreach ( $pairs as [ $value, $weight ] ) {
            $r -= $weight;
            if ( $r < 0 ) {
                return $value;
            }
        }

        return $pairs[ count( $pairs ) - 1 ][0];
    }

    public function poisson( float $mean ): int
    {
        if ( $mean > 30 ) { // normal approximation for large means
            $u = max( $this->next(), 1e-12 );

            return max( 0, (int) round( $mean + sqrt( $mean ) * sqrt( -2 * log( $u ) ) * cos( 2 * M_PI * $this->next() ) ) );
        }
        $limit = exp( -$mean );
        $k = 0;
        $p = 1.0;
        do {
            $k++;
            $p *= $this->next();
        } while ( $p > $limit );

        return $k - 1;
    }
}
