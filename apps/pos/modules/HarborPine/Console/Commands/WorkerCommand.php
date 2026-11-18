<?php
namespace Modules\HarborPine\Console\Commands;

use Carbon\Carbon;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Modules\HarborPine\Services\Catalog;
use Modules\HarborPine\Services\Simulator;
use Throwable;

/**
 * Live simulation loop (run as a Windows service). Each tick processes the events that became due,
 * honours pause/resume, holds a lock so only one worker runs, and exits after --max-minutes or when
 * memory grows (the service wrapper restarts it), which bounds resource use.
 */
class WorkerCommand extends Command
{
    protected $signature = 'hp:worker {--tick=60 : seconds between ticks} {--intensity=1} {--max-minutes=120} {--max-memory=192}';

    protected $description = 'Harbor & Pine Market: live simulation worker.';

    public function handle( Catalog $catalog, Simulator $sim )
    {
        // A MariaDB named lock is held for this connection's lifetime and released automatically
        // if the process dies: at most one live worker, no stale lock files.
        if ( (int) DB::selectOne( "select get_lock('harborpine-sim-worker', 0) as l" )->l !== 1 ) {
            $this->warn( 'another worker holds the lock' );

            return self::SUCCESS;
        }
        $tz = $catalog->store()['timezone'];
        $deadline = time() + 60 * (int) $this->option( 'max-minutes' );
        try {
            while ( time() < $deadline ) {
                try {
                    $state = $sim->state();
                    if ( $state && ! $state->paused ) {
                        $before = DB::table( 'harborpine_sim_ledger' )->count();
                        $sim->run( Carbon::now( $tz ), (float) $this->option( 'intensity' ) );
                        $new = DB::table( 'harborpine_sim_ledger' )->count() - $before;
                        if ( $new > 0 ) {
                            $this->line( sprintf( '[%s] %d event(s) processed', Carbon::now( $tz )->format( 'Y-m-d H:i:s' ), $new ) );
                        }
                    }
                } catch ( Throwable $e ) {
                    $this->error( '[' . Carbon::now( $tz )->format( 'Y-m-d H:i:s' ) . '] tick failed: ' . $e->getMessage() );
                }
                if ( memory_get_usage( true ) / 1048576 > (int) $this->option( 'max-memory' ) ) {
                    $this->line( 'memory limit reached, exiting for a clean restart' );
                    break;
                }
                sleep( max( 10, (int) $this->option( 'tick' ) ) );
            }
        } finally {
            DB::selectOne( "select release_lock('harborpine-sim-worker') as l" );
        }

        return self::SUCCESS;
    }
}
