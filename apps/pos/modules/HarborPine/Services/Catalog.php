<?php
namespace Modules\HarborPine\Services;

use RuntimeException;

/**
 * Curated Harbor & Pine Market source values (Data/catalog.json) expanded into concrete SKUs.
 * Expansion is deterministic: the same catalog always yields the same SKUs, barcodes and prices.
 */
class Catalog
{
    public array $data;

    /** @var array<int, array> expanded sellable items */
    private ?array $items = null;

    public function __construct( array $data )
    {
        $this->data = $data;
    }

    public static function load( string $path ): self
    {
        $data = json_decode( file_get_contents( $path ), true );
        if ( ! is_array( $data ) ) {
            throw new RuntimeException( "Invalid catalog file: $path" );
        }

        return new self( $data );
    }

    public function store(): array
    {
        return $this->data['store'];
    }

    public function category( string $key ): array
    {
        foreach ( $this->data['categories'] as $c ) {
            if ( $c['key'] === $key ) {
                return $c;
            }
        }
        throw new RuntimeException( "Unknown category $key" );
    }

    /** Retail shelf price: cost × markup, rounded to .49/.99 endings like a real shelf label. */
    public static function shelfPrice( float $cost, float $markup ): float
    {
        $raw = $cost * $markup;
        if ( $raw < 10 ) {
            return round( ceil( $raw * 2 ) / 2 - 0.01, 2 );
        }

        return round( ceil( $raw ) - 0.01, 2 );
    }

    /** EAN-13 with a valid check digit in the in-store range (prefix 2), from a numeric seed. */
    public static function ean13( int $n ): string
    {
        $body = '2' . str_pad( (string) ( 10000000000 + $n ), 11, '0', STR_PAD_LEFT );
        $body = substr( $body, 0, 12 );
        $sum = 0;
        for ( $i = 0; $i < 12; $i++ ) {
            $sum += (int) $body[ $i ] * ( $i % 2 === 0 ? 1 : 3 );
        }

        return $body . ( ( 10 - $sum % 10 ) % 10 );
    }

    /**
     * Every sellable item: one per product × size variant.
     * Keys: sku, barcode, name, category, brand, description, cost, price, tax, popularity, perishable.
     *
     * @return array<int, array>
     */
    public function items(): array
    {
        if ( $this->items !== null ) {
            return $this->items;
        }
        $rng = Rng::forKey( 20261118, 'catalog-expansion' );
        $items = [];
        $n = 0;
        foreach ( $this->data['products'] as $catKey => $products ) {
            $cat = $this->category( $catKey );
            $brands = $this->data['brands'][ $catKey ];
            foreach ( $products as $pIndex => [ $base, $form, $sizes, $costs, $description ] ) {
                $brand = $brands[ $pIndex % count( $brands ) ];
                // Product-level popularity: a few hero products sell much more than the long tail.
                $productPopularity = $cat['popularity'] * ( $rng->chance( 0.2 ) ? 2.5 : 0.6 + $rng->next() );
                foreach ( $sizes as $vIndex => $size ) {
                    $n++;
                    $cost = (float) $costs[ min( $vIndex, count( $costs ) - 1 ) ];
                    $markup = $cat['markup'][0] + $rng->next() * ( $cat['markup'][1] - $cat['markup'][0] );
                    $brandCode = strtoupper( substr( preg_replace( '/[^A-Za-z]/', '', $brand ), 0, 3 ) );
                    $items[] = [
                        'sku' => sprintf( '%s-%s-%04d', strtoupper( substr( $catKey, 0, 3 ) ), $brandCode, 1000 + $n ),
                        'barcode' => self::ean13( 7300000 + $n * 17 ),
                        'name' => count( $sizes ) > 1 || ! in_array( $size, [ 'each', '1 loaf' ] ) ? "$base — $size" : $base,
                        'category' => $catKey,
                        'base' => $base,
                        'brand' => $brand,
                        'form' => $form,
                        'description' => "$brand. $description",
                        'cost' => $cost,
                        'price' => self::shelfPrice( $cost, $markup ),
                        'tax' => $cat['tax'],
                        // Larger packs sell less often than the single unit.
                        'popularity' => round( $productPopularity * ( $vIndex === 0 ? 1 : 0.45 ), 3 ),
                        'perishable' => (bool) ( $cat['perishable'] ?? false ),
                    ];
                }
            }
        }

        return $this->items = $items;
    }

    /** Count of curated source values (for the ~500 target). */
    public function curatedValueCount(): int
    {
        $d = $this->data;
        $n = count( $d['categories'] ) + count( $d['taxGroups'] ) + count( $d['suppliers'] ) + count( $d['staff'] )
            + count( $d['customers']['firstNames'] ) + count( $d['customers']['lastNames'] ) + count( $d['customers']['groups'] )
            + count( $d['promotions'] ) + count( $d['returns']['reasons'] ) + count( $d['adjustments']['reasons'] )
            + count( $d['demand']['weekday'] ) + count( $d['demand']['month'] ) + count( $d['demand']['hour'] )
            + count( $d['demand']['basketItems'] ) + count( $d['store']['hours'] ) + count( $d['store']['registers'] );
        foreach ( $d['brands'] as $list ) {
            $n += count( $list );
        }
        foreach ( $d['products'] as $products ) {
            foreach ( $products as [ $base, $form, $sizes, $costs, $description ] ) {
                $n += 3 + count( $sizes ) + count( $costs ); // name, form, description, sizes, costs
            }
        }

        return $n;
    }
}
