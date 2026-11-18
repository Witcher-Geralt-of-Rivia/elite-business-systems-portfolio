<?php
namespace Modules\HarborPine\Services;

use App\Services\DateService;
use App\Services\ProductService;
use App\Services\ReportService;
use Carbon\Carbon;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\DB;
use RuntimeException;

/**
 * Persisted simulation state + range execution for backfill and live operation.
 * `processed_until` (store-local time) is the watermark: every event at or before it has run.
 */
class Simulator
{
    public function __construct( private Catalog $catalog )
    {
    }

    public function state(): ?object
    {
        return DB::table( 'harborpine_sim_state' )->where( 'id', 1 )->first();
    }

    public function initialize( int $seed, Carbon $scenarioStart ): void
    {
        DB::table( 'harborpine_sim_state' )->updateOrInsert( [ 'id' => 1 ], [
            'seed' => $seed, 'scenario_start' => $scenarioStart->format( 'Y-m-d' ),
            'processed_until' => $scenarioStart->copy()->startOfDay()->format( 'Y-m-d H:i:s' ),
            'paused' => false, 'intensity' => 1, 'stats' => json_encode( [] ),
            'created_at' => now(), 'updated_at' => now(),
        ] );
    }

    public function engine( float $intensity = 1.0 ): RetailEngine
    {
        $s = $this->state() ?? throw new RuntimeException( 'Simulation not initialized: run hp:backfill first.' );
        $engine = new RetailEngine( $this->catalog, (int) $s->seed, $s->scenario_start );
        $engine->intensity = $intensity;
        $engine->boot();

        return $engine;
    }

    /**
     * Executes every planned event in (from, to], day by day, and advances the watermark after each day.
     *
     * @return array<string,int> counters
     */
    public function run( Carbon $to, float $intensity = 1.0, ?callable $progress = null, bool $deferReports = false ): array
    {
        if ( $deferReports ) {
            app()->bind( ReportService::class, fn() => new DeferredReportService( app()->make( DateService::class ), app()->make( ProductService::class ) ) );
        }
        try {
            return $this->runRange( $to, $intensity, $progress );
        } finally {
            if ( $deferReports ) {
                app()->bind( ReportService::class, fn() => new ReportService( app()->make( DateService::class ), app()->make( ProductService::class ) ) );
            }
        }
    }

    private function runRange( Carbon $to, float $intensity, ?callable $progress ): array
    {
        $engine = $this->engine( $intensity );
        $tz = $engine->tz();
        $state = $this->state();
        $from = Carbon::parse( $state->processed_until, $tz );
        $to = $to->copy()->setTimezone( $tz );
        $day = $from->copy()->startOfDay();
        while ( $day->lte( $to ) ) {
            foreach ( $engine->planDay( $day ) as $event ) {
                if ( $event['at']->gt( $from ) && $event['at']->lte( $to ) ) {
                    $engine->execute( $event );
                }
            }
            $watermark = $day->copy()->endOfDay()->min( $to );
            DB::table( 'harborpine_sim_state' )->where( 'id', 1 )->update( [
                'processed_until' => $watermark->format( 'Y-m-d H:i:s' ),
                'stats' => json_encode( $this->mergeStats( $engine->counters ) ),
                'updated_at' => Carbon::now(),
            ] );
            $engine->counters = [];
            $progress && $progress( $day->format( 'Y-m-d' ) );
            $day->addDay();
        }

        return json_decode( $this->state()->stats, true );
    }

    private function mergeStats( array $counters ): array
    {
        $stats = json_decode( $this->state()->stats ?? '[]', true ) ?: [];
        foreach ( $counters as $k => $v ) {
            $stats[ $k ] = ( $stats[ $k ] ?? 0 ) + $v;
        }

        return $stats;
    }

    /** Rebuilds NexoPOS's precomputed day/month dashboards in chronological order. */
    public function recomputeReports( Carbon $from ): void
    {
        Carbon::setTestNow();
        Artisan::call( 'ns:report', [ '--compute' => true, '--type' => 'day', '--from' => $from->format( 'Y-m-d' ) ] );
        Artisan::call( 'ns:report', [ '--compute' => true, '--type' => 'month', '--from' => $from->format( 'Y-m-d' ) ] );
    }

    public function setPaused( bool $paused ): void
    {
        DB::table( 'harborpine_sim_state' )->where( 'id', 1 )->update( [ 'paused' => $paused, 'updated_at' => Carbon::now() ] );
    }
}
