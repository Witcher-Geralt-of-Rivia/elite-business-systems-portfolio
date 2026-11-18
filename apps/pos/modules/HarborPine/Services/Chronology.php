<?php
namespace Modules\HarborPine\Services;

use App\Services\Options;
use Carbon\Carbon;
use Illuminate\Support\Facades\DB;

/**
 * Store setup (hp:setup) runs on the real clock, so catalog, supplier, register and customer records carry
 * the build time while the trading history starts at the scenario start. This aligns them once, in store
 * local time like every other NexoPOS timestamp:
 *  - setup records (catalog, suppliers, taxes, registers, payment types, groups, staff, units) are dated in
 *    the three weeks before opening;
 *  - each registered customer is dated 0–25 days before their first purchase (never before the setup weeks),
 *    customers without purchases are spread over the trading period.
 * Only creation/update timestamps of those setup records change: no order, payment, stock or report data.
 * Deterministic (seeded) and applied once (option harborpine_chronology).
 */
class Chronology
{
    public const OPTION = 'harborpine_chronology';

    private const SETUP_TABLES = [
        'nexopos_products_categories', 'nexopos_products', 'nexopos_products_unit_quantities', 'nexopos_products_taxes',
        'nexopos_products_galleries', 'nexopos_providers', 'nexopos_units', 'nexopos_units_groups', 'nexopos_taxes',
        'nexopos_taxes_groups', 'nexopos_registers', 'nexopos_payments_types', 'nexopos_customers_groups',
    ];

    public function __construct( private Catalog $catalog ) {}

    public function apply( bool $force = false ): array
    {
        if ( ! $force && ns()->option->get( self::OPTION ) === 'applied' ) {
            return [ 'status' => 'already applied' ];
        }
        $state = DB::table( 'harborpine_sim_state' )->first();
        $tz = $this->catalog->store()['timezone'];
        $opening = Carbon::parse( $state->scenario_start, $tz )->startOfDay();
        $setupStart = $opening->copy()->subDays( 21 )->setTime( 9, 0 );
        // Records written by the setup run carry wall-clock times after the history starts.
        $setupWritten = $opening->copy()->addDay()->format( 'Y-m-d H:i:s' );
        $out = [];

        DB::transaction( function () use ( $setupStart, $setupWritten, $state, $tz, $opening, &$out ) {
            foreach ( self::SETUP_TABLES as $table ) {
                $rows = DB::table( $table )->where( 'created_at', '>', $setupWritten )->orderBy( 'id' )->pluck( 'id' );
                foreach ( $rows as $i => $id ) {
                    // Spread over the setup weeks in working hours, in creation order.
                    $at = $setupStart->copy()->addDays( intdiv( $i, 30 ) % 18 )->addMinutes( 7 * ( $i % 30 ) )->format( 'Y-m-d H:i:s' );
                    DB::table( $table )->where( 'id', $id )->update( [ 'created_at' => $at, 'updated_at' => $at ] );
                }
                $out[ $table ] = count( $rows );
            }

            // People: staff and the walk-in record belong to the setup; registered customers to their first visit.
            $firstOrder = DB::table( 'nexopos_orders' )->select( 'customer_id', DB::raw( 'MIN(created_at) AS first_at' ) )
                ->groupBy( 'customer_id' )->pluck( 'first_at', 'customer_id' );
            $customers = DB::table( 'nexopos_users AS u' )
                ->join( 'nexopos_users_roles_relations AS r', 'r.user_id', '=', 'u.id' )
                ->join( 'nexopos_roles AS ro', 'ro.id', '=', 'r.role_id' )
                ->where( 'ro.namespace', 'nexopos.store.customer' )
                ->where( 'u.created_at', '>', $setupWritten )
                ->pluck( 'u.email', 'u.id' );
            $tradingDays = max( 1, $opening->diffInDays( Carbon::parse( $state->processed_until, $tz ) ) );
            $moved = 0;
            foreach ( $customers as $id => $email ) {
                $rng = Rng::forKey( (int) $state->seed, "customer-since:$id" );
                if ( str_starts_with( (string) $email, 'walk-in@' ) ) {
                    $at = $setupStart->copy();
                } elseif ( isset( $firstOrder[ $id ] ) ) {
                    $at = Carbon::parse( $firstOrder[ $id ], $tz )->subDays( $rng->int( 0, 25 ) )->setTime( $rng->int( 9, 17 ), $rng->int( 0, 59 ) );
                    if ( $at->lt( $setupStart ) ) {
                        $at = $setupStart->copy()->addDays( $rng->int( 0, 17 ) )->setTime( $rng->int( 9, 17 ), $rng->int( 0, 59 ) );
                    }
                    if ( $at->gt( Carbon::parse( $firstOrder[ $id ], $tz ) ) ) {
                        $at = Carbon::parse( $firstOrder[ $id ], $tz )->subMinutes( 5 );
                    }
                } else {
                    $at = $opening->copy()->addDays( $rng->int( 0, $tradingDays ) )->setTime( $rng->int( 9, 17 ), $rng->int( 0, 59 ) );
                }
                DB::table( 'nexopos_users' )->where( 'id', $id )->update( [ 'created_at' => $at->format( 'Y-m-d H:i:s' ), 'updated_at' => $at->format( 'Y-m-d H:i:s' ) ] );
                $moved++;
            }
            $out['customers'] = $moved;

            $staff = DB::table( 'nexopos_users AS u' )
                ->join( 'nexopos_users_roles_relations AS r', 'r.user_id', '=', 'u.id' )
                ->join( 'nexopos_roles AS ro', 'ro.id', '=', 'r.role_id' )
                ->whereIn( 'ro.namespace', [ 'admin', 'nexopos.store.administrator', 'nexopos.store.cashier' ] )
                ->where( 'u.created_at', '>', $setupWritten )
                ->pluck( 'u.id' );
            foreach ( $staff as $i => $id ) {
                $at = $setupStart->copy()->subDays( 7 - $i )->format( 'Y-m-d H:i:s' );
                DB::table( 'nexopos_users' )->where( 'id', $id )->update( [ 'created_at' => $at, 'updated_at' => $at ] );
            }
            $out['staff'] = count( $staff );
        } );

        app( Options::class )->set( self::OPTION, 'applied' );

        return $out;
    }
}
