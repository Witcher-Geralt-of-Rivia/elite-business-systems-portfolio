<?php
namespace Modules\HarborPine\Console\Commands;

use Carbon\Carbon;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Modules\HarborPine\Services\Simulator;

/**
 * Determinism / recovery proof (read-only): recomputes the seeded plan of the last N processed days and
 * compares it with the idempotency ledger. A deterministic engine that never skipped or duplicated an event
 * yields 0 missing, 0 unexpected and 0 time mismatches — which is what makes restarts and catch-up safe.
 */
class ReplayCheckCommand extends Command
{
    protected $signature = 'hp:replay-check {--days=14 : processed days to verify} {--json}';

    protected $description = 'Harbor & Pine Market: verify that the ledger matches the deterministic plan (read-only).';

    public function handle( Simulator $sim )
    {
        $state = $sim->state();
        $engine = $sim->engine( (float) $state->intensity );
        $tz = $engine->tz();
        $until = Carbon::parse( $state->processed_until, $tz );
        $result = [ 'days' => 0, 'planned' => 0, 'ledger' => 0, 'missing' => 0, 'unexpected' => 0, 'time_mismatch' => 0, 'kind_mismatch' => 0, 'samples' => [] ];
        for ( $i = (int) $this->option( 'days' ) - 1; $i >= 0; $i-- ) {
            $day = $until->copy()->startOfDay()->subDays( $i );
            $planned = collect( $engine->planDay( $day ) )->filter( fn( $e ) => $e['at']->lte( $until ) )->keyBy( 'key' );
            $ledger = DB::table( 'harborpine_sim_ledger' )->where( 'event_key', 'like', $day->format( 'Y-m-d' ) . ':%' )->get()->keyBy( 'event_key' );
            $result['days']++;
            $result['planned'] += $planned->count();
            $result['ledger'] += $ledger->count();
            foreach ( $planned as $key => $e ) {
                $row = $ledger->get( $key );
                if ( ! $row ) {
                    $result['missing']++;
                    $result['samples'][] = "missing $key";

                    continue;
                }
                if ( $row->kind !== $e['kind'] ) {
                    $result['kind_mismatch']++;
                    $result['samples'][] = "kind $key";
                }
                if ( $row->occurred_at !== $e['at']->format( 'Y-m-d H:i:s' ) ) {
                    $result['time_mismatch']++;
                    $result['samples'][] = "time $key {$row->occurred_at} vs {$e['at']->format( 'Y-m-d H:i:s' )}";
                }
            }
            foreach ( $ledger->keys()->diff( $planned->keys() ) as $key ) {
                $result['unexpected']++;
                $result['samples'][] = "unexpected $key";
            }
        }
        $result['samples'] = array_slice( $result['samples'], 0, 10 );
        $this->line( json_encode( $result, JSON_PRETTY_PRINT ) );

        return ( $result['missing'] + $result['unexpected'] + $result['time_mismatch'] + $result['kind_mismatch'] ) === 0 ? self::SUCCESS : self::FAILURE;
    }
}
