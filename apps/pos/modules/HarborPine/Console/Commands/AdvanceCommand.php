<?php
namespace Modules\HarborPine\Console\Commands;

use Carbon\Carbon;
use Illuminate\Console\Command;
use Modules\HarborPine\Services\Catalog;
use Modules\HarborPine\Services\Simulator;

class AdvanceCommand extends Command
{
    protected $signature = 'hp:advance {--until= : store-local time (default now)} {--intensity=1}';

    protected $description = 'Harbor & Pine Market: process all business events up to now (one live tick).';

    public function handle( Catalog $catalog, Simulator $sim )
    {
        $state = $sim->state();
        if ( ! $state ) {
            $this->warn( 'not initialized' );

            return self::FAILURE;
        }
        if ( $state->paused ) {
            $this->line( 'paused' );

            return self::SUCCESS;
        }
        $tz = $catalog->store()['timezone'];
        $until = $this->option( 'until' ) ? Carbon::parse( $this->option( 'until' ), $tz ) : Carbon::now( $tz );
        $sim->run( $until, (float) $this->option( 'intensity' ) );
        $this->line( 'advanced to ' . $until->format( 'Y-m-d H:i:s' ) );

        return self::SUCCESS;
    }
}
