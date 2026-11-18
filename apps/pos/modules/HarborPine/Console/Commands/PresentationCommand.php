<?php
namespace Modules\HarborPine\Console\Commands;

use Illuminate\Console\Command;
use Modules\HarborPine\Services\Artwork;
use Modules\HarborPine\Services\StoreBuilder;

class PresentationCommand extends Command
{
    protected $signature = 'hp:presentation';

    protected $description = 'Harbor & Pine Market: apply display preferences and attach the catalog artwork (idempotent; no stock, prices or sales).';

    public function handle( Artwork $artwork )
    {
        StoreBuilder::presentation();
        $result = $artwork->apply( StoreBuilder::admin()->id );
        $this->line( json_encode( $result, JSON_PRETTY_PRINT ) );

        return $result['missing'] ? self::FAILURE : self::SUCCESS;
    }
}
