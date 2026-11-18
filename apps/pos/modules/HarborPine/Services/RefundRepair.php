<?php
namespace Modules\HarborPine\Services;

use App\Models\Order;
use App\Models\RegisterHistory;
use App\Services\OrdersService;
use Carbon\Carbon;
use Illuminate\Support\Facades\DB;

/**
 * One-off correction of fully returned promotional purchases made before the engine took the discount
 * share out with each returned unit.
 *
 * NexoPOS keeps a flat order discount when lines are refunded. When the last line of a discounted order was
 * returned, refreshOrder() left the order at total = -discount with payment status "paid", and because the
 * order still looked paid, NexoPOS re-recorded its cash change at the register balance of the refund day,
 * breaking that register's balance chain.
 *
 * For each such order: the promotion is withdrawn (discount 0) and NexoPOS refreshOrder() recomputes it
 * (total 0, status "refunded", as for any fully returned order), without re-firing order listeners (cashier
 * stats, rewards and the refund were already booked when the return happened). The cash-change entry is
 * restored to the change actually handed out at the sale (tendered minus the sale total recorded in the
 * ledger) at its original position in the register chain. Daily/monthly reports are then recomputed from
 * the first affected day. Refund amounts, stock movements and payments are not changed. Idempotent.
 */
class RefundRepair
{
    public function __construct( private OrdersService $orders, private Simulator $sim ) {}

    public function candidates()
    {
        return Order::where( 'payment_status', Order::PAYMENT_PAID )->where( 'total', '<', 0 )
            ->whereExists( fn( $q ) => $q->select( DB::raw( 1 ) )->from( 'nexopos_orders_refunds' )->whereColumn( 'nexopos_orders_refunds.order_id', 'nexopos_orders.id' ) )
            ->orderBy( 'id' )->get();
    }

    public function run( bool $dryRun = false ): array
    {
        $orders = $this->candidates();
        $out = [ 'orders' => $orders->count(), 'codes' => $orders->pluck( 'code' )->all(), 'change_entries_restored' => 0, 'change_entries_removed' => 0, 'reports_from' => null ];
        if ( $dryRun || $orders->isEmpty() ) {
            return $out;
        }

        foreach ( $orders as $order ) {
            DB::transaction( function () use ( $order, &$out ) {
                $sale = DB::table( 'harborpine_sim_ledger' )->where( 'entity', 'order' )->where( 'entity_id', $order->id )->first();
                $saleTotal = $sale ? (float) ( json_decode( $sale->details, true )['total'] ?? 0 ) : null;

                $order->discount = 0;
                $order->saveQuietly();
                Order::withoutEvents( fn() => $this->orders->refreshOrder( Order::with( 'payments', 'refunds' )->find( $order->id ) ) );

                $entry = RegisterHistory::where( 'order_id', $order->id )->where( 'action', RegisterHistory::ACTION_ORDER_CHANGE )->first();
                if ( $entry && $saleTotal !== null ) {
                    $change = round( (float) $order->tendered - $saleTotal, 2 );
                    if ( $change <= 0 ) {
                        // No change was given at the sale (card or exact cash): NexoPOS created this cash-out
                        // in the session of the refund day. Remove it and give the cash back to the rest of
                        // that session, closing count included (the drawer held that amount all along).
                        $value = (float) $entry->value;
                        $nextOpening = DB::table( 'nexopos_registers_history' )->where( 'register_id', $entry->register_id )
                            ->where( 'id', '>', $entry->id )->where( 'action', RegisterHistory::ACTION_OPENING )->min( 'id' );
                        $session = fn() => DB::table( 'nexopos_registers_history' )->where( 'register_id', $entry->register_id )
                            ->where( 'id', '>', $entry->id )->when( $nextOpening, fn( $q ) => $q->where( 'id', '<', $nextOpening ) );
                        $closed = $session()->where( 'action', RegisterHistory::ACTION_CLOSING )->exists();
                        $session()->where( 'action', '<>', RegisterHistory::ACTION_CLOSING )->update( [
                            'balance_before' => DB::raw( 'balance_before + ' . $value ), 'balance_after' => DB::raw( 'balance_after + ' . $value ),
                        ] );
                        $session()->where( 'action', RegisterHistory::ACTION_CLOSING )->update( [
                            'balance_before' => DB::raw( 'balance_before + ' . $value ), 'value' => DB::raw( 'value + ' . $value ),
                        ] );
                        if ( ! $closed ) {
                            DB::table( 'nexopos_registers' )->where( 'id', $entry->register_id )->update( [ 'balance' => DB::raw( 'balance + ' . $value ) ] );
                        }
                        DB::table( 'nexopos_registers_history' )->where( 'id', $entry->id )->delete();
                        $out['change_entries_removed']++;
                    } else {
                        $previous = DB::table( 'nexopos_registers_history' )->where( 'register_id', $entry->register_id )
                            ->where( 'id', '<', $entry->id )->orderByDesc( 'id' )->value( 'balance_after' );
                        $before = (float) ( $previous ?? $entry->balance_before );
                        DB::table( 'nexopos_registers_history' )->where( 'id', $entry->id )->update( [
                            'value' => $change, 'balance_before' => $before, 'balance_after' => round( $before - $change, 2 ),
                        ] );
                        $out['change_entries_restored']++;
                    }
                }
            }, 3 );
        }

        $tz = app( Catalog::class )->store()['timezone'];
        $from = Carbon::parse( $orders->min( 'created_at' ), $tz )->startOfDay();
        $this->sim->recomputeReports( $from );
        $out['reports_from'] = $from->format( 'Y-m-d' );

        return $out;
    }
}
