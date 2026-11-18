<?php
namespace Modules\HarborPine\Console\Commands;

use App\Models\Customer;
use App\Models\Order;
use App\Models\Product;
use App\Services\OrdersService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Modules\HarborPine\Services\StoreBuilder;

/**
 * Creates one mixed-tax order inside a transaction that is ROLLED BACK, and prints what NexoPOS
 * stored, to verify tax/total/payment behaviour before any bulk generation. Leaves no data behind.
 */
class ProbeOrderCommand extends Command
{
    protected $signature = 'hp:probe-order';

    protected $description = 'Verify order tax/total handling with a rolled-back test order.';

    public function handle( OrdersService $orders )
    {
        Auth::login( StoreBuilder::admin() );
        $food = Product::where( 'sku', 'like', 'COF-%' )->with( 'unit_quantities' )->first();
        $general = Product::where( 'sku', 'like', 'CAN-%' )->with( 'unit_quantities' )->first();
        $customer = Customer::where( 'email', 'walk-in@harborandpine.example' )->firstOrFail();
        DB::beginTransaction();
        try {
            // Stock: products start at 0, so put a little on hand inside the rolled-back transaction.
            foreach ( [ $food, $general ] as $p ) {
                $p->unit_quantities[0]->quantity = 10;
                $p->unit_quantities[0]->save();
            }
            $lines = [];
            $net = 0; $tax = 0;
            foreach ( [ [ $food, 2, 0 ], [ $general, 1, 8.9 ] ] as [ $p, $qty, $rate ] ) {
                $uq = $p->unit_quantities[0];
                $lines[] = [ 'product_id' => $p->id, 'unit_quantity_id' => $uq->id, 'unit_id' => $uq->unit_id, 'quantity' => $qty, 'unit_price' => $uq->sale_price_edit ];
                $net += $uq->sale_price_edit * $qty;
                $tax += round( $uq->sale_price_edit * $qty * $rate / 100, 2 );
            }
            $total = round( $net + $tax, 2 );
            $result = $orders->create( [
                'customer_id' => $customer->id, 'type' => [ 'identifier' => 'takeaway' ],
                'products' => $lines, 'tax_type' => 'exclusive', 'tax_value' => $tax,
                'payments' => [ [ 'identifier' => StoreBuilder::CARD, 'value' => $total ] ],
            ] );
            $order = Order::with( 'products', 'payments' )->find( $result['data']['order']->id );
            $this->line( json_encode( [
                'sent' => compact( 'net', 'tax', 'total' ),
                'order' => $order->only( [ 'subtotal', 'tax_value', 'products_tax_value', 'total', 'tendered', 'change', 'payment_status', 'tax_type' ] ),
                'lines' => $order->products->map( fn( $l ) => $l->only( [ 'name', 'quantity', 'unit_price', 'tax_value', 'total_price', 'price_with_tax', 'tax_group_id' ] ) ),
                'payments' => $order->payments->map( fn( $p ) => $p->only( [ 'identifier', 'value' ] ) ),
                'stock_after' => [ $food->fresh()->unit_quantities[0]->quantity, $general->fresh()->unit_quantities[0]->quantity ],
            ], JSON_PRETTY_PRINT ) );
        } finally {
            DB::rollBack();
        }

        return self::SUCCESS;
    }
}
