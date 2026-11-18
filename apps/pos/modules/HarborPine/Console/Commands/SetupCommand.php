<?php
namespace Modules\HarborPine\Console\Commands;

use Illuminate\Console\Command;
use Modules\HarborPine\Services\Catalog;
use Modules\HarborPine\Services\StoreBuilder;

class SetupCommand extends Command
{
    protected $signature = 'hp:setup';

    protected $description = 'Harbor & Pine Market: create settings, taxes, catalog, suppliers, staff, customers and registers (idempotent).';

    public function handle( Catalog $catalog )
    {
        $summary = ( new StoreBuilder( $catalog ) )->build( fn( $m ) => $this->line( $m ) );
        $this->info( json_encode( $summary ) );

        return self::SUCCESS;
    }
}
