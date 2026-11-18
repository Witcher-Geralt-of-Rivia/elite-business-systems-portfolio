<?php
namespace Modules\HarborPine\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Modules\HarborPine\Services\Simulator;

class ControlCommand extends Command
{
    protected $signature = 'hp:sim {action : status|pause|resume}';

    protected $description = 'Harbor & Pine Market: show simulation status, pause or resume the live simulation.';

    public function handle( Simulator $sim )
    {
        $action = $this->argument( 'action' );
        if ( in_array( $action, [ 'pause', 'resume' ], true ) ) {
            $sim->setPaused( $action === 'pause' );
        }
        $s = $sim->state();
        $this->line( json_encode( $s ? [
            'seed' => (int) $s->seed, 'scenario_start' => $s->scenario_start, 'processed_until' => $s->processed_until,
            'paused' => (bool) $s->paused, 'ledger_events' => DB::table( 'harborpine_sim_ledger' )->count(),
            'stats' => json_decode( $s->stats, true ),
        ] : 'not initialized', JSON_PRETTY_PRINT ) );

        return self::SUCCESS;
    }
}
