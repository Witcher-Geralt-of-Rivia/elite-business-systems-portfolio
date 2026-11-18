<?php
namespace Modules\HarborPine\Console\Commands;

use Illuminate\Console\Command;
use Modules\HarborPine\Services\Artwork;
use Modules\HarborPine\Services\Chronology;
use Modules\HarborPine\Services\StoreBuilder;

class PresentationCommand extends Command
{
    protected $signature = 'hp:presentation {--skip-chronology : leave setup/customer timestamps untouched (e.g. while a backfill runs)}';

    protected $description = 'Harbor & Pine Market: display preferences, catalog artwork and setup-record chronology (idempotent; no stock, prices or sales).';

    public function handle( Artwork $artwork, Chronology $chronology )
    {
        StoreBuilder::presentation();
        $result = [ 'artwork' => $artwork->apply( StoreBuilder::admin()->id ) ];
        if ( ! $this->option( 'skip-chronology' ) ) {
            $result['chronology'] = $chronology->apply();
        }
        $this->line( json_encode( $result, JSON_PRETTY_PRINT ) );

        return $result['artwork']['missing'] ? self::FAILURE : self::SUCCESS;
    }
}
