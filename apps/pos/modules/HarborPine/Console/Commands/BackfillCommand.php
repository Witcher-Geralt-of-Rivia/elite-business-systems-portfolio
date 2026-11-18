<?php
namespace Modules\HarborPine\Console\Commands;

use Carbon\Carbon;
use Illuminate\Console\Command;
use Modules\HarborPine\Services\Catalog;
use Modules\HarborPine\Services\Simulator;

/**
 * Generates Harbor & Pine Market history through NexoPOS services, then rebuilds the precomputed
 * reports. Resumable: rerunning continues from the watermark; already-executed events are skipped.
 */
class BackfillCommand extends Command
{
    protected $signature = 'hp:backfill {--seed=20261118} {--months=12} {--until= : store-local end time (default: now)} {--days= : only this many days (testing)}';

    protected $description = 'Harbor & Pine Market: generate deterministic retail history and recompute reports.';

    public function handle( Catalog $catalog, Simulator $sim )
    {
        $tz = $catalog->store()['timezone'];
        $until = $this->option( 'until' ) ? Carbon::parse( $this->option( 'until' ), $tz ) : Carbon::now( $tz );
        if ( ! $sim->state() ) {
            $start = $until->copy()->subMonthsNoOverflow( (int) $this->option( 'months' ) )->startOfDay();
            $sim->initialize( (int) $this->option( 'seed' ), $start );
            $this->info( "initialized: seed {$this->option( 'seed' )}, scenario start {$start->format( 'Y-m-d' )}" );
        }
        if ( $this->option( 'days' ) ) {
            $from = Carbon::parse( $sim->state()->processed_until, $tz );
            $until = $from->copy()->addDays( (int) $this->option( 'days' ) )->endOfDay()->min( $until );
        }
        $t0 = microtime( true );
        $stats = $sim->run( $until, 1.0, function ( $day ) use ( $t0 ) {
            $this->line( sprintf( '%s done  (%.0fs elapsed, %.0f MB)', $day, microtime( true ) - $t0, memory_get_usage( true ) / 1048576 ) );
        }, deferReports: true );
        $this->info( 'recomputing reports…' );
        $sim->recomputeReports( Carbon::parse( $sim->state()->scenario_start, $tz ) );
        $this->info( json_encode( $stats ) );

        return self::SUCCESS;
    }
}
