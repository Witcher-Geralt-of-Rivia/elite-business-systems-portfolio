<?php
namespace Modules\HarborPine\Services;

use App\Models\Customer;
use App\Models\CustomerGroup;
use App\Models\Order;
use App\Models\OrderProduct;
use App\Models\Product;
use App\Models\ProductHistory;
use App\Models\Provider;
use App\Models\Register;
use App\Models\User;
use App\Services\CashRegistersService;
use App\Services\OrdersService;
use App\Services\ProcurementService;
use App\Services\ProductService;
use Carbon\Carbon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Throwable;

/**
 * Harbor & Pine Market operating model, executed through NexoPOS services.
 *
 * Each store day is planned deterministically from (seed, date): supplier deliveries before opening,
 * register sessions, customer sales spread over opening hours, returns of earlier purchases, weekly
 * perishable waste, monthly shrink. Every event has a stable key; it is executed at most once
 * (ledger row written in the same DB transaction as the records it creates), so a backfill, a live
 * tick, a restart or a crash replay never duplicates business records.
 */
class RetailEngine
{
    public const FLOATS = [ 'Front Counter' => 200.0, 'Café Counter' => 150.0 ];

    private array $items;          // catalog items keyed by sku

    private array $productIds = [];   // sku => product id

    private array $uq = [];           // sku => [unit_quantity_id, unit_id, price]

    private array $taxRate = [];      // sku => rate %

    private array $customersByGroup = [];

    private int $walkInId;

    private array $staff = [];        // username => User

    private array $registers = [];    // name => Register

    private array $groupDiscount = []; // customer group id => percent

    public array $counters = [];

    public float $intensity = 1.0;

    public function __construct( private Catalog $catalog, private int $seed, private string $scenarioStart )
    {
        $this->items = [];
        foreach ( $catalog->items() as $item ) {
            $this->items[ $item['sku'] ] = $item;
        }
    }

    // ------------------------------------------------------------------ bootstrapping
    public function boot(): void
    {
        foreach ( Product::with( 'unit_quantities' )->whereIn( 'sku', array_keys( $this->items ) )->get() as $p ) {
            $uq = $p->unit_quantities->first();
            $this->productIds[ $p->sku ] = $p->id;
            $this->uq[ $p->sku ] = [ $uq->id, $uq->unit_id, (float) $uq->sale_price_edit ];
        }
        foreach ( $this->items as $sku => $item ) {
            $this->taxRate[ $sku ] = $item['tax'] === 'general' ? (float) collect( $this->catalog->data['taxGroups'] )->firstWhere( 'key', 'general' )['rate'] : 0.0;
        }
        $this->walkInId = Customer::where( 'email', 'walk-in@harborandpine.example' )->value( 'id' );
        foreach ( CustomerGroup::all() as $g ) {
            $ids = Customer::where( 'group_id', $g->id )->where( 'id', '<>', $this->walkInId )->orderBy( 'id' )->pluck( 'id' )->all();
            $this->customersByGroup[ $g->name ] = $ids;
            $conf = collect( $this->catalog->data['customers']['groups'] )->firstWhere( 'name', $g->name );
            $this->groupDiscount[ $g->id ] = (float) ( $conf['discountPercent'] ?? 0 );
        }
        foreach ( $this->catalog->data['staff'] as $s ) {
            $this->staff[ $s['username'] ] = User::where( 'username', $s['username'] )->firstOrFail();
        }
        foreach ( $this->catalog->store()['registers'] as $name ) {
            $this->registers[ $name ] = Register::where( 'name', $name )->firstOrFail();
        }
    }

    // ------------------------------------------------------------------ calendar
    public function tz(): string
    {
        return $this->catalog->store()['timezone'];
    }

    public function isOpen( Carbon $day ): bool
    {
        return ! in_array( $day->format( 'm-d' ), $this->catalog->store()['closedDates'], true );
    }

    /** @return array{0:int,1:int} opening and closing hour, store-local */
    public function hours( Carbon $day ): array
    {
        return $this->catalog->store()['hours'][ (string) $day->dayOfWeek ];
    }

    private function demandFactor( Carbon $day ): float
    {
        $d = $this->catalog->data['demand'];
        $years = Carbon::parse( $this->scenarioStart, $this->tz() )->diffInDays( $day ) / 365;

        return $d['weekday'][ (string) $day->dayOfWeek ] * $d['month'][ (string) $day->month ] * ( 1 + $d['growthPerYear'] * $years );
    }

    // ------------------------------------------------------------------ planning
    /**
     * Deterministic event plan for one store-local day. Times are store-local.
     *
     * @return array<int, array{key:string, kind:string, at:Carbon, data:array}>
     */
    public function planDay( Carbon $day ): array
    {
        $day = $day->copy()->startOfDay();
        $date = $day->format( 'Y-m-d' );
        if ( ! $this->isOpen( $day ) ) {
            return [];
        }
        $rng = Rng::forKey( $this->seed, "plan:$date" );
        [ $open, $close ] = $this->hours( $day );
        $events = [];
        $dayIndex = (int) Carbon::parse( $this->scenarioStart, $this->tz() )->startOfDay()->diffInDays( $day );

        // Supplier deliveries arrive before opening on each supplier's cadence (day 0: opening stock).
        foreach ( $this->catalog->data['suppliers'] as $i => $s ) {
            $offset = $i % max( 1, $s['cadenceDays'] );
            if ( $dayIndex === 0 || ( $dayIndex >= $offset && ( $dayIndex - $offset ) % $s['cadenceDays'] === 0 ) ) {
                $events[] = $this->event( "$date:delivery:$i", 'delivery', $day->copy()->setTime( $open - 1, 10 + $i * 3 ), [ 'supplier' => $i, 'opening' => $dayIndex === 0 ] );
            }
        }
        // Registers open at opening time and close after the last customer.
        foreach ( array_keys( $this->registers ) as $r => $name ) {
            $events[] = $this->event( "$date:open:$r", 'open_register', $day->copy()->setTime( $open, 0 )->subMinutes( 10 - $r ), [ 'register' => $name ] );
            $events[] = $this->event( "$date:close:$r", 'close_register', $day->copy()->setTime( $close, 10 + $r ), [ 'register' => $name ] );
        }
        // Customer sales, distributed over opening hours by the hourly traffic curve.
        $hourWeights = [];
        foreach ( $this->catalog->data['demand']['hour'] as $h => $w ) {
            if ( (int) $h >= $open && (int) $h < $close ) {
                $hourWeights[] = [ (int) $h, (float) $w ];
            }
        }
        $sales = $rng->poisson( $this->catalog->data['demand']['baseOrdersPerDay'] * $this->demandFactor( $day ) * $this->intensity );
        $times = [];
        for ( $n = 0; $n < $sales; $n++ ) {
            $hour = $rng->weighted( $hourWeights );
            $times[] = $day->copy()->setTime( $hour, $rng->int( 0, 59 ), $rng->int( 0, 59 ) );
        }
        sort( $times );
        foreach ( $times as $n => $t ) {
            $events[] = $this->event( sprintf( '%s:sale:%03d', $date, $n ), 'sale', $t, [] );
        }
        // Returns of earlier purchases (~1.2% of sales, within the return window).
        $returns = $rng->poisson( $sales * $this->catalog->data['demand']['returnRate'] );
        for ( $n = 0; $n < $returns; $n++ ) {
            $events[] = $this->event( "$date:return:$n", 'return', $day->copy()->setTime( $rng->int( $open + 1, $close - 1 ), $rng->int( 0, 59 ) ), [] );
        }
        // Mondays: perishable waste count. First Monday of the month: shrink/cycle count.
        if ( $day->dayOfWeek === Carbon::MONDAY && $dayIndex > 0 ) {
            $events[] = $this->event( "$date:waste", 'waste', $day->copy()->setTime( $close, 30 ), [] );
            if ( $day->day <= 7 ) {
                $events[] = $this->event( "$date:shrink", 'shrink', $day->copy()->setTime( $close, 40 ), [] );
            }
        }
        usort( $events, fn( $a, $b ) => [ $a['at']->timestamp, $a['key'] ] <=> [ $b['at']->timestamp, $b['key'] ] );

        return $events;
    }

    private function event( string $key, string $kind, Carbon $at, array $data ): array
    {
        return [ 'key' => $key, 'kind' => $kind, 'at' => $at, 'data' => $data ];
    }

    // ------------------------------------------------------------------ execution
    /** Runs one event exactly once. Returns false if it was already recorded. */
    public function execute( array $event ): bool
    {
        if ( DB::table( 'harborpine_sim_ledger' )->where( 'event_key', $event['key'] )->exists() ) {
            return false;
        }
        $this->setClock( $event['at'] );
        try {
            return DB::transaction( function () use ( $event ) {
                // Re-check inside the transaction (unique index is the final guard).
                if ( DB::table( 'harborpine_sim_ledger' )->where( 'event_key', $event['key'] )->lockForUpdate()->exists() ) {
                    return false;
                }
                $rng = Rng::forKey( $this->seed, 'event:' . $event['key'] );
                [ $entity, $id, $details ] = match ( $event['kind'] ) {
                    'delivery' => $this->delivery( $event, $rng ),
                    'open_register' => $this->openRegister( $event ),
                    'close_register' => $this->closeRegister( $event ),
                    'sale' => $this->sale( $event, $rng ),
                    'return' => $this->returnItem( $event, $rng ),
                    'waste' => $this->waste( $event, $rng ),
                    'shrink' => $this->shrink( $event, $rng ),
                };
                DB::table( 'harborpine_sim_ledger' )->insert( [
                    'event_key' => $event['key'], 'kind' => $event['kind'], 'occurred_at' => $event['at']->format( 'Y-m-d H:i:s' ),
                    'entity' => $entity, 'entity_id' => $id, 'details' => $details ? json_encode( $details ) : null,
                    'recorded_at' => Carbon::now()->format( 'Y-m-d H:i:s' ),
                ] );
                $this->counters[ $event['kind'] . ( $entity ? '' : '_skipped' ) ] = ( $this->counters[ $event['kind'] . ( $entity ? '' : '_skipped' ) ] ?? 0 ) + 1;

                return true;
            }, 3 ); // a deadlock with a concurrent writer (e.g. a cashier) is retried; the ledger keeps it exactly-once
        } finally {
            Carbon::setTestNow();
        }
    }

    /** Both NexoPOS clocks: Carbon (row timestamps) and ns()->date (day reports), in store time. */
    public function setClock( Carbon $localTime ): void
    {
        $utc = $localTime->copy()->setTimezone( 'UTC' );
        Carbon::setTestNow( $utc );
        ns()->date->define( $localTime->copy(), $this->tz() );
    }

    private function as( string $username ): User
    {
        $user = $this->staff[ $username ];
        Auth::login( $user );

        return $user;
    }

    private function onShift( string $register, Carbon $at, Rng $rng ): string
    {
        $weekend = in_array( $at->dayOfWeek, [ Carbon::SATURDAY, Carbon::SUNDAY ], true );
        $pairs = [];
        foreach ( $this->catalog->data['staff'] as $s ) {
            if ( $s['register'] !== $register ) {
                continue;
            }
            if ( str_contains( $s['role'], 'weekend' ) && ! $weekend ) {
                continue;
            }
            $pairs[] = [ $s['username'], $s['shiftShare'] * $s['speed'] ];
        }

        return $rng->weighted( $pairs );
    }

    private function stock( string $sku ): float
    {
        return (float) DB::table( 'nexopos_products_unit_quantities' )->where( 'id', $this->uq[ $sku ][0] )->value( 'quantity' );
    }

    /** Expected units sold per day for one SKU (catalog popularity share of average daily items). */
    private function dailyDemand( string $sku ): float
    {
        static $totalPopularity = null;
        $totalPopularity ??= array_sum( array_column( $this->items, 'popularity' ) );
        $d = $this->catalog->data['demand'];
        $avgItems = 0;
        $weights = array_sum( array_column( $d['basketItems'], 1 ) );
        foreach ( $d['basketItems'] as [ $k, $w ] ) {
            $avgItems += $k * $w / $weights;
        }

        return $d['baseOrdersPerDay'] * $avgItems * 1.15 * $this->items[ $sku ]['popularity'] / $totalPopularity;
    }

    // --- delivery: purchase order received from a supplier (stock up to cover the next cycle) ---
    private function delivery( array $event, Rng $rng ): array
    {
        $supplier = $this->catalog->data['suppliers'][ $event['data']['supplier'] ];
        $provider = Provider::where( 'email', $supplier['email'] )->firstOrFail();
        $this->as( $this->catalog->data['staff'][0]['username'] ); // the store manager receives goods
        $season = $this->demandFactor( $event['at'] ) * $this->intensity;
        $lead = ( $supplier['leadDays'][0] + $supplier['leadDays'][1] ) / 2;
        $lines = [];
        $total = 0;
        foreach ( $this->items as $sku => $item ) {
            if ( $this->supplierFor( $item ) !== $supplier['name'] ) {
                continue;
            }
            $daily = max( 0.2, $this->dailyDemand( $sku ) * $season );
            $cover = $item['perishable'] ? $supplier['cadenceDays'] + 1 : $supplier['cadenceDays'] + $lead + 4;
            $target = $daily * $cover * ( $event['data']['opening'] ? 1.3 : 1.0 );
            $onHand = $this->stock( $sku );
            if ( $onHand >= $target * 0.6 && ! $event['data']['opening'] ) {
                continue; // enough stock until the next delivery
            }
            $case = $item['perishable'] ? 6 : ( $item['cost'] > 15 ? 2 : 12 );
            $qty = (int) max( $case, ceil( ( $target - $onHand ) / $case ) * $case );
            $cost = round( $item['cost'] * ( 0.97 + $rng->next() * 0.06 ), 2 ); // supplier price drift
            $lines[] = [
                'product_id' => $this->productIds[ $sku ], 'unit_id' => $this->uq[ $sku ][1], 'quantity' => $qty,
                'purchase_price' => $cost, 'gross_purchase_price' => $cost, 'net_purchase_price' => $cost,
                'tax_type' => 'inclusive', 'tax_value' => 0, 'total_purchase_price' => round( $cost * $qty, 2 ),
            ];
            $total += $cost * $qty;
        }
        if ( ! $lines ) {
            return [ null, null, [ 'reason' => 'stock sufficient' ] ];
        }
        $at = $event['at']->format( 'Y-m-d H:i:s' );
        $ordered = $event['at']->copy()->subDays( (int) round( $lead ) )->format( 'Y-m-d' );
        $result = app( ProcurementService::class )->create( [
            'name' => sprintf( 'PO-%s-%02d', $event['at']->format( 'ymd' ), $event['data']['supplier'] + 1 ),
            'general' => [
                'provider_id' => $provider->id, 'payment_status' => 'paid', 'delivery_status' => 'delivered',
                'invoice_reference' => sprintf( 'INV-%s-%04d', strtoupper( substr( preg_replace( '/[^A-Za-z]/', '', $supplier['name'] ), 0, 4 ) ), crc32( $event['key'] ) % 10000 ),
                'invoice_date' => $event['at']->format( 'Y-m-d' ),
                'description' => "Ordered $ordered, {$supplier['terms']}",
                'created_at' => $at, 'updated_at' => $at,
            ],
            'products' => $lines,
        ] );
        $procurement = $result['data']['procurement'] ?? null;

        return [ 'procurement', $procurement?->id, [ 'lines' => count( $lines ), 'value' => round( $total, 2 ) ] ];
    }

    private function supplierFor( array $item ): string
    {
        // Brand-owned suppliers first, otherwise the category distributor.
        foreach ( $this->catalog->data['suppliers'] as $s ) {
            if ( $s['name'] === $item['brand'] && in_array( $item['category'], $s['categories'], true ) ) {
                return $s['name'];
            }
        }
        foreach ( $this->catalog->data['suppliers'] as $s ) {
            if ( in_array( $item['category'], $s['categories'], true ) && count( $s['categories'] ) > 1 ) {
                return $s['name'];
            }
        }
        foreach ( $this->catalog->data['suppliers'] as $s ) {
            if ( in_array( $item['category'], $s['categories'], true ) ) {
                return $s['name'];
            }
        }

        return '';
    }

    // --- registers ---
    private function openRegister( array $event ): array
    {
        $name = $event['data']['register'];
        $register = $this->registers[ $name ]->fresh();
        $cashier = $this->onShift( $name, $event['at'], Rng::forKey( $this->seed, 'shift:' . $event['at']->format( 'Y-m-d' ) . $name ) );
        $this->as( $cashier );
        if ( $register->status === Register::STATUS_OPENED ) {
            // Left open by an interrupted day: close at its recorded balance before reopening.
            app( CashRegistersService::class )->closeRegister( $register, (float) $register->balance, 'Closed at next opening' );
            $register = $register->fresh();
        }
        app( CashRegistersService::class )->openRegister( $register, self::FLOATS[ $name ] ?? 150.0, 'Opening float' );

        return [ 'register', $register->id, [ 'cashier' => $cashier, 'float' => self::FLOATS[ $name ] ?? 150.0 ] ];
    }

    private function closeRegister( array $event ): array
    {
        $register = $this->registers[ $event['data']['register'] ]->fresh();
        if ( $register->status !== Register::STATUS_OPENED ) {
            return [ null, null, [ 'reason' => 'not open' ] ];
        }
        $this->as( $this->catalog->data['staff'][0]['username'] );
        // Counted amount equals the recorded balance: the till reconciles.
        $balance = (float) $register->balance;
        app( CashRegistersService::class )->closeRegister( $register, $balance, 'End of day count' );

        return [ 'register', $register->id, [ 'closing_balance' => $balance ] ];
    }

    // --- sales ---
    private function sale( array $event, Rng $rng ): array
    {
        $at = $event['at'];
        $registerName = $rng->chance( 0.72 ) ? 'Front Counter' : 'Café Counter';
        $register = $this->registers[ $registerName ]->fresh();
        if ( $register->status !== Register::STATUS_OPENED ) {
            return [ null, null, [ 'reason' => 'register closed' ] ];
        }
        $cashier = $this->as( $this->onShift( $registerName, $at, $rng ) );

        // Customer: registered members/accounts or the walk-in till customer.
        $customerId = $this->walkInId;
        $groupName = 'Walk-in';
        if ( $rng->chance( $this->catalog->data['demand']['registeredCustomerShare'] ) ) {
            $groupName = $rng->weighted( array_map( fn( $g ) => [ $g['name'], $g['share'] ], $this->catalog->data['customers']['groups'] ) );
            $pool = $this->customersByGroup[ $groupName ] ?: $this->customersByGroup['Walk-in'];
            // A loyal core shops far more often than the long tail.
            $customerId = $pool[ (int) floor( count( $pool ) * pow( $rng->next(), 1.8 ) ) ];
        }

        // Basket: size distribution; products weighted by popularity, café counter favours food & drink.
        $size = $rng->weighted( $this->catalog->data['demand']['basketItems'] );
        $month = $at->month;
        $weights = [];
        foreach ( $this->items as $sku => $item ) {
            $w = $item['popularity'];
            if ( in_array( $item['category'], [ 'gifts', 'candles', 'table' ], true ) && in_array( $month, [ 11, 12 ], true ) ) {
                $w *= 2.6;
            }
            if ( $item['category'] === 'drinks' && in_array( $month, [ 6, 7, 8 ], true ) ) {
                $w *= 1.5;
            }
            if ( $registerName === 'Café Counter' && ! in_array( $item['category'], [ 'coffee', 'bakery', 'drinks', 'snacks' ], true ) ) {
                $w *= 0.15;
            }
            $weights[] = [ $sku, $w ];
        }
        $basket = [];
        for ( $i = 0; $i < $size * 2 && count( $basket ) < $size; $i++ ) {
            $sku = $rng->weighted( $weights );
            if ( isset( $basket[ $sku ] ) ) {
                continue;
            }
            $qty = $rng->weighted( [ [ 1, 82 ], [ 2, 14 ], [ 3, 4 ] ] );
            $available = $this->stock( $sku );
            if ( $available < 1 ) {
                continue; // out of stock: the customer skips it
            }
            $basket[ $sku ] = (int) min( $qty, floor( $available ) );
        }
        if ( ! $basket ) {
            return [ null, null, [ 'reason' => 'nothing in stock' ] ];
        }

        $lines = [];
        $subtotal = 0.0;
        $taxable = 0.0;
        foreach ( $basket as $sku => $qty ) {
            [ $uqId, $unitId, $price ] = $this->uq[ $sku ];
            $lines[] = [ 'product_id' => $this->productIds[ $sku ], 'unit_quantity_id' => $uqId, 'unit_id' => $unitId, 'quantity' => $qty, 'unit_price' => $price ];
            $subtotal += $price * $qty;
            if ( $this->taxRate[ $sku ] > 0 ) {
                $taxable += $price * $qty;
            }
        }
        $subtotal = round( $subtotal, 2 );

        // Discounts: member group discount, else a seasonal promotion when the basket qualifies.
        $discountPct = 0.0;
        $discountFlat = 0.0;
        $promo = null;
        $customer = Customer::find( $customerId );
        $groupPct = $this->groupDiscount[ $customer->group_id ] ?? 0;
        if ( $groupPct > 0 ) {
            $discountPct = $groupPct;
            $promo = $groupPct >= 10 ? 'ACCOUNT10' : 'HARBORCLUB5';
        } else {
            foreach ( $this->catalog->data['promotions'] as $p ) {
                if ( ! in_array( $month, $p['months'], true ) || ! $rng->chance( 0.35 ) ) {
                    continue;
                }
                if ( $p['type'] === 'flat' && $subtotal >= 30 ) {
                    $discountFlat = (float) $p['value'];
                    $promo = $p['code'];
                    break;
                }
                if ( $p['type'] === 'percentage' ) {
                    $discountPct = (float) $p['value'];
                    $promo = $p['code'];
                    break;
                }
            }
        }
        $discount = $discountPct > 0 ? round( $subtotal * $discountPct / 100, 2 ) : $discountFlat;
        // Sales tax applies to the discounted taxable amount (discount spread pro rata).
        $taxableAfter = $subtotal > 0 ? $taxable * ( 1 - $discount / $subtotal ) : 0;
        $rate = (float) collect( $this->catalog->data['taxGroups'] )->firstWhere( 'key', 'general' )['rate'];
        $tax = round( $taxableAfter * $rate / 100, 2 );
        $total = round( $subtotal - $discount + $tax, 2 );

        $method = $rng->weighted( array_map( fn( $p ) => [ $p[0], $p[1] ], $this->catalog->data['demand']['paymentMix'] ) );
        if ( $method === 'cash' ) {
            $tendered = $total;
            foreach ( [ 1, 5, 10, 20, 50, 100 ] as $note ) {
                if ( $rng->chance( $note <= 5 ? 0.35 : 0.5 ) || $note === 100 ) {
                    $tendered = ceil( $total / $note ) * $note;
                    break;
                }
            }
            $payment = [ 'identifier' => 'cash-payment', 'value' => round( $tendered, 2 ) ];
        } else {
            $payment = [ 'identifier' => StoreBuilder::CARD, 'value' => $total ];
        }

        $fields = [
            'customer_id' => $customerId, 'type' => [ 'identifier' => 'takeaway' ], 'author_id' => $cashier->id,
            'register_id' => $register->id, 'products' => $lines, 'tax_type' => 'exclusive', 'tax_value' => $tax,
            'payments' => [ $payment ],
            'note' => $promo ? "Promotion $promo" : null,
        ];
        // Discounts are sent as the already-rounded amount: NexoPOS would otherwise recompute a
        // percentage from unrounded values and totals would drift by fractions of a cent.
        if ( $discount > 0 ) {
            $fields += [ 'discount_type' => 'flat', 'discount_percentage' => 0, 'discount' => $discount ];
            $fields['note'] = sprintf( 'Promotion %s (%s)', $promo, $discountPct > 0 ? rtrim( rtrim( number_format( $discountPct, 2 ), '0' ), '.' ) . '%' : '$' . number_format( $discountFlat, 2 ) );
        }
        $result = app( OrdersService::class )->create( $fields );
        $order = $result['data']['order'];

        return [ 'order', $order->id, [ 'total' => $total, 'tax' => $tax, 'discount' => $discount, 'method' => $method, 'promo' => $promo, 'items' => array_sum( $basket ) ] ];
    }

    // --- returns: one item of a recent paid purchase comes back ---
    private function returnItem( array $event, Rng $rng ): array
    {
        $window = $this->catalog->data['returns']['windowDays'];
        // NexoPOS stores timestamps in the store timezone (app.timezone = ns_datetime_timezone).
        $since = $event['at']->copy()->subDays( $window )->format( 'Y-m-d H:i:s' );
        $until = $event['at']->copy()->subDay()->format( 'Y-m-d H:i:s' );
        $candidates = Order::whereIn( 'payment_status', [ Order::PAYMENT_PAID, Order::PAYMENT_PARTIALLY_REFUNDED ] )
            ->whereBetween( 'created_at', [ $since, $until ] )->orderBy( 'id' )->pluck( 'id' );
        if ( $candidates->isEmpty() ) {
            return [ null, null, [ 'reason' => 'no eligible purchase' ] ];
        }
        $order = Order::with( 'products', 'payments' )->find( $candidates[ (int) floor( $rng->next() * $candidates->count() ) ] );
        $line = $order->products->filter( fn( $l ) => $l->quantity > 0 )->values();
        if ( $line->isEmpty() ) {
            return [ null, null, [ 'reason' => 'nothing left to refund' ] ];
        }
        /** @var OrderProduct $line */
        $line = $line[ (int) floor( $rng->next() * $line->count() ) ];
        $this->as( $this->catalog->data['staff'][0]['username'] );
        $restock = $rng->chance( $this->catalog->data['returns']['restockShare'] );
        $reason = $rng->pick( $this->catalog->data['returns']['reasons'] );
        $method = $order->payments->first()?->identifier ?? 'cash-payment';
        $result = app( OrdersService::class )->refundOrder( $order, [
            'payment' => [ 'identifier' => $method ],
            'refund_shipping' => false,
            'total' => (float) $line->unit_price,
            'products' => [ [
                'id' => $line->id, 'quantity' => 1, 'unit_price' => (float) $line->unit_price,
                'condition' => $restock ? 'unspoiled' : 'damaged', 'description' => $reason,
            ] ],
        ] );
        $refund = $result['data']['orderRefund'] ?? null;

        return [ 'refund', $refund?->id, [ 'order_id' => $order->id, 'reason' => $reason, 'restocked' => $restock ] ];
    }

    // --- inventory adjustments ---
    private function waste( array $event, Rng $rng ): array
    {
        $this->as( $this->catalog->data['staff'][0]['username'] );
        $adjusted = 0;
        [ $lo, $hi ] = $this->catalog->data['adjustments']['perishableWastePerWeek'];
        foreach ( $this->items as $sku => $item ) {
            if ( ! $item['perishable'] ) {
                continue;
            }
            $qty = (int) floor( $this->stock( $sku ) * ( $lo + $rng->next() * ( $hi - $lo ) ) );
            if ( $qty < 1 ) {
                continue;
            }
            $this->adjust( $sku, $qty, ProductHistory::ACTION_DEFECTIVE, 'Expired' );
            $adjusted++;
        }

        return [ $adjusted ? 'adjustment' : null, null, [ 'lines' => $adjusted ] ];
    }

    private function shrink( array $event, Rng $rng ): array
    {
        $this->as( $this->catalog->data['staff'][0]['username'] );
        $adjusted = 0;
        [ $lo, $hi ] = $this->catalog->data['adjustments']['shrinkPerMonth'];
        foreach ( $this->items as $sku => $item ) {
            $stock = $this->stock( $sku );
            if ( $item['perishable'] || $stock < 20 || ! $rng->chance( 0.25 ) ) {
                continue;
            }
            $qty = max( 1, (int) round( $stock * ( $lo + $rng->next() * ( $hi - $lo ) ) ) );
            $reason = $rng->pick( [ 'Breakage', 'Count correction', 'Damaged packaging' ] );
            $this->adjust( $sku, $qty, $reason === 'Breakage' ? ProductHistory::ACTION_DEFECTIVE : ProductHistory::ACTION_LOST, $reason );
            $adjusted++;
        }

        return [ $adjusted ? 'adjustment' : null, null, [ 'lines' => $adjusted ] ];
    }

    private function adjust( string $sku, int $qty, string $action, string $reason ): void
    {
        [ $uqId, $unitId ] = $this->uq[ $sku ];
        app( ProductService::class )->stockAdjustment( $action, [
            'product_id' => $this->productIds[ $sku ], 'unit_id' => $unitId, 'quantity' => $qty,
            'unit_price' => $this->items[ $sku ]['cost'], 'total_price' => round( $this->items[ $sku ]['cost'] * $qty, 2 ),
            'description' => $reason,
        ] );
    }
}
