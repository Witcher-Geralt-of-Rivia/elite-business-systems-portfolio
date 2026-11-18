<?php
namespace Modules\HarborPine\Services;

use App\Models\Product;
use App\Models\ProductCategory;
use App\Models\ProductGallery;

/**
 * Attaches the module's original catalog artwork (apps/pos/scripts/generate-artwork.py) to categories
 * (preview_url) and products (one featured gallery image) through NexoPOS's own models. Idempotent: an
 * image this module attached earlier is updated in place; galleries added by anyone else are left alone.
 * This touches presentation only (no stock, prices or sales).
 */
class Artwork
{
    public const BASE_URL = '/modules/harborpine/images';

    public const GALLERY_NAME = 'harborpine-artwork';

    public function __construct( private Catalog $catalog ) {}

    public function apply( int $authorId ): array
    {
        $shapes = json_decode( file_get_contents( dirname( __DIR__ ) . '/Data/artwork-shapes.json' ), true );
        $publicDir = dirname( __DIR__ ) . '/Public/images';
        $out = [ 'categories' => 0, 'products' => 0, 'missing' => [] ];

        foreach ( $this->catalog->data['categories'] as $c ) {
            $category = ProductCategory::where( 'name', $c['name'] )->first();
            if ( $category && $category->preview_url !== self::BASE_URL . "/categories/{$c['key']}.svg" ) {
                $category->preview_url = self::BASE_URL . "/categories/{$c['key']}.svg";
                $category->save();
            }
            $out['categories'] += $category ? 1 : 0;
        }

        foreach ( $this->catalog->items() as $item ) {
            $shape = $shapes['shapeByForm'][ $item['form'] ] ?? $shapes['categoryShape'][ $item['category'] ];
            $file = sprintf( '%s-%s-%d.svg', $item['category'], $shape, crc32( $item['base'] ) % 3 );
            if ( ! is_file( "$publicDir/products/$file" ) ) {
                $out['missing'][] = $file;

                continue;
            }
            $product = Product::where( 'sku', $item['sku'] )->first();
            if ( ! $product ) {
                continue;
            }
            $gallery = ProductGallery::where( 'product_id', $product->id )->where( 'name', self::GALLERY_NAME )->first() ?? new ProductGallery;
            $gallery->name = self::GALLERY_NAME;
            $gallery->product_id = $product->id;
            $gallery->url = self::BASE_URL . "/products/$file";
            $gallery->featured = true;
            $gallery->order = 0;
            $gallery->author_id = $gallery->author_id ?: $authorId;
            $gallery->save();
            $out['products']++;
        }

        return $out;
    }
}
