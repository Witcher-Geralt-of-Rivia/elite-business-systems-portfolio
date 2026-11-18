<?php
namespace Modules\HarborPine\Console\Commands;

use Carbon\Carbon;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Event;
use Modules\HarborPine\Services\Simulator;

/**
 * Profiles one simulated sale (inside a rolled-back transaction): wall time, query count and the
 * most expensive SQL statement shapes. Diagnostic only; leaves no data behind.
 */
class ProfileSaleCommand extends Command
{
    protected $signature = 'hp:profile-sale {--at= : store-local time of an open business hour}';

    protected $description = 'Profile the cost of one simulated sale (rolled back).';

    public function handle( Simulator $sim )
    {
        $engine = $sim->engine();
        $at = Carbon::parse( $this->option( 'at' ) ?? $sim->state()->processed_until, $engine->tz() );
        $shapes = [];
        $count = 0;
        DB::listen( function ( $q ) use ( &$shapes, &$count ) {
            $count++;
            $shape = preg_replace( '/\s+/', ' ', substr( $q->sql, 0, 90 ) );
            $shapes[ $shape ] = ( $shapes[ $shape ] ?? [ 0, 0 ] );
            $shapes[ $shape ][0]++;
            $shapes[ $shape ][1] += $q->time;
        } );
        $events = [];
        Event::listen( '*', function ( $name ) use ( &$events ) {
            if ( str_starts_with( $name, 'App\\' ) ) {
                $events[ $name ] = ( $events[ $name ] ?? 0 ) + 1;
            }
        } );
        DB::beginTransaction();
        \App\Models\Register::query()->update( [ 'status' => \App\Models\Register::STATUS_OPENED ] );
        $count = 0;
        $shapes = [];
        $t0 = microtime( true );
        $walls = [];
        try {
            foreach ( range( 1, 4 ) as $i ) {
                $t1 = microtime( true );
                $engine->execute( [ 'key' => 'profile:' . uniqid(), 'kind' => 'sale', 'at' => $at->copy()->addMinutes( $i ), 'data' => [] ] );
                $walls[] = round( microtime( true ) - $t1, 2 );
            }
            $this->line( 'per-sale wall seconds: ' . json_encode( $walls ) );
        } finally {
            $elapsed = microtime( true ) - $t0;
            DB::rollBack();
        }
        uasort( $shapes, fn( $a, $b ) => $b[1] <=> $a[1] );
        $this->line( sprintf( 'wall %.2fs, %d queries, %.2fs in SQL', $elapsed, $count, array_sum( array_column( $shapes, 1 ) ) / 1000 ) );
        foreach ( array_slice( $shapes, 0, 14, true ) as $shape => [ $n, $ms ] ) {
            $this->line( sprintf( '%5d x %8.1f ms  %s', $n, $ms, $shape ) );
        }
        arsort( $events );
        $this->line( 'events: ' . json_encode( array_slice( $events, 0, 12, true ) ) );

        return self::SUCCESS;
    }
}
