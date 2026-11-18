<?php
namespace Modules\HarborPine\Services;

use App\Models\Customer;
use App\Models\CustomerGroup;
use App\Models\PaymentType;
use App\Models\Product;
use App\Models\ProductCategory;
use App\Models\Provider;
use App\Models\Register;
use App\Models\Role;
use App\Models\Tax;
use App\Models\TaxGroup;
use App\Models\Unit;
use App\Models\UnitGroup;
use App\Models\User;
use App\Services\CustomerService;
use App\Services\Options;
use App\Services\ProductCategoryService;
use App\Services\ProductService;
use App\Services\ProviderService;
use App\Services\TaxService;
use App\Services\UnitService;
use App\Services\UsersService;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;
use RuntimeException;

/**
 * Builds the Harbor & Pine Market store through NexoPOS services. Idempotent: every entity is
 * looked up by a natural key (name, sku, email, identifier) before being created.
 */
class StoreBuilder
{
    public const CARD = 'card-payment';
    public const UNIT_IDENTIFIER = 'hp-each';

    public function __construct( private Catalog $catalog )
    {
    }

    public static function admin(): User
    {
        $admin = Role::namespace( Role::ADMIN )->users()->orderBy( 'id' )->first();
        if ( ! $admin ) {
            throw new RuntimeException( 'No NexoPOS administrator found: run the store setup first.' );
        }

        return $admin;
    }

    /** @return array<string,int> summary counts */
    public function build( callable $log ): array
    {
        Auth::login( self::admin() );
        $this->options();
        $log( 'options set' );
        $this->paymentTypes();
        $taxGroups = $this->taxes();
        $unit = $this->unit();
        $categories = $this->categories();
        $providers = $this->providers();
        $log( 'taxes, unit, categories, suppliers ready' );
        $products = $this->products( $taxGroups, $unit, $categories, $log );
        $staff = $this->staff();
        $groups = $this->customerGroups();
        $customers = $this->customers( $groups, $log );
        $registers = $this->registers();

        return [
            'products' => $products, 'categories' => count( $categories ), 'suppliers' => count( $providers ),
            'staff' => count( $staff ), 'customers' => $customers, 'registers' => count( $registers ),
        ];
    }

    private function options(): void
    {
        /** @var Options $o */
        $o = app( Options::class );
        $s = $this->catalog->store();
        $o->set( 'ns_store_name', $s['name'] );
        $o->set( 'ns_store_address', $s['address'] );
        $o->set( 'ns_store_phone', $s['phone'] );
        $o->set( 'ns_store_email', $s['email'] );
        $o->set( 'ns_currency_iso', $s['currency'] );
        $o->set( 'ns_currency_symbol', '$' );
        $o->set( 'ns_currency_position', 'before' );
        $o->set( 'ns_currency_precision', 2 );
        $o->set( 'ns_currency_decimal_separator', '.' );
        $o->set( 'ns_currency_thousand_separator', ',' );
        $o->set( 'ns_datetime_timezone', $s['timezone'] );
        // Taxes are defined per product (US sales tax: groceries exempt, general merchandise taxed).
        $o->set( 'ns_pos_vat', 'products_vat' );
        $o->set( 'ns_pos_registers_enabled', 'yes' );
        $o->set( 'ns_orders_allow_partial', 'no' );
        $o->set( 'ns_orders_allow_incomplete', 'no' );
        $o->set( 'ns_pos_order_types', [ 'takeaway' ] );
        self::presentation();
    }

    /** Display-only preferences (safe to re-apply on a populated store). */
    public static function presentation(): void
    {
        $o = app( Options::class );
        $o->set( 'ns_currency_prefered', 'symbol' ); // "$12.49" rather than "USD12.49"
        // Like a real counter: a new cart starts on the walk-in customer (members are picked when they show a card).
        $walkIn = User::where( 'email', 'walk-in@harborandpine.example' )->value( 'id' );
        if ( $walkIn ) {
            $o->set( 'ns_customers_default', $walkIn );
        }
    }

    private function paymentTypes(): void
    {
        // Change given back is recorded against the cash payment type (the option expects its id).
        app( Options::class )->set( 'ns_pos_registers_default_change_payment_type', PaymentType::where( 'identifier', 'cash-payment' )->value( 'id' ) );
        if ( ! PaymentType::where( 'identifier', self::CARD )->exists() ) {
            $p = new PaymentType;
            $p->label = 'Card (simulated)';
            $p->identifier = self::CARD;
            $p->author_id = Auth::id();
            $p->active = true;
            $p->priority = 2;
            $p->save();
        }
    }

    /** @return array<string,int> tax key => tax group id */
    private function taxes(): array
    {
        /** @var TaxService $taxes */
        $taxes = app( TaxService::class );
        $out = [];
        foreach ( $this->catalog->data['taxGroups'] as $g ) {
            $group = TaxGroup::where( 'name', $g['name'] )->first();
            if ( ! $group ) {
                $group = $taxes->createTaxGroup( [ 'name' => $g['name'], 'description' => "Harbor & Pine: {$g['name']}" ] );
                $group = $group instanceof TaxGroup ? $group : TaxGroup::where( 'name', $g['name'] )->firstOrFail();
            }
            if ( ! Tax::where( 'tax_group_id', $group->id )->exists() ) {
                $taxes->createTax( [ 'name' => $g['rate'] > 0 ? "Port Alder sales tax {$g['rate']}%" : 'Grocery exemption', 'rate' => $g['rate'], 'tax_group_id' => $group->id, 'description' => '' ] );
            }
            $out[ $g['key'] ] = $group->id;
        }

        return $out;
    }

    private function unit(): Unit
    {
        $unit = Unit::where( 'identifier', self::UNIT_IDENTIFIER )->first();
        if ( $unit ) {
            return $unit;
        }
        /** @var UnitService $units */
        $units = app( UnitService::class );
        $group = UnitGroup::where( 'name', 'Retail units' )->first();
        if ( ! $group ) {
            $units->createGroup( [ 'name' => 'Retail units', 'description' => 'Items sold individually' ] );
            $group = UnitGroup::where( 'name', 'Retail units' )->firstOrFail();
        }
        $units->createUnit( [ 'name' => 'Each', 'identifier' => self::UNIT_IDENTIFIER, 'group_id' => $group->id, 'value' => 1, 'base_unit' => true, 'description' => 'Single item' ] );

        return Unit::where( 'identifier', self::UNIT_IDENTIFIER )->firstOrFail();
    }

    /** @return array<string,int> category key => id */
    private function categories(): array
    {
        /** @var ProductCategoryService $service */
        $service = app( ProductCategoryService::class );
        $out = [];
        foreach ( $this->catalog->data['categories'] as $c ) {
            $cat = ProductCategory::where( 'name', $c['name'] )->first();
            if ( ! $cat ) {
                $service->create( [ 'name' => $c['name'], 'description' => '', 'displays_on_pos' => true ] );
                $cat = ProductCategory::where( 'name', $c['name'] )->firstOrFail();
            }
            $out[ $c['key'] ] = $cat->id;
        }

        return $out;
    }

    /** @return array<string,int> supplier name => provider id */
    private function providers(): array
    {
        /** @var ProviderService $service */
        $service = app( ProviderService::class );
        $out = [];
        foreach ( $this->catalog->data['suppliers'] as $i => $s ) {
            $p = Provider::where( 'email', $s['email'] )->first();
            if ( ! $p ) {
                $service->create( [
                    'first_name' => $s['name'], 'email' => $s['email'], 'phone' => sprintf( '+1 360-555-01%02d', 50 + $i ),
                    'address_1' => 'Port Alder, WA', 'description' => "Categories: " . implode( ', ', $s['categories'] ) . ". Terms: {$s['terms']}. Lead time {$s['leadDays'][0]}–{$s['leadDays'][1]} days.",
                ] );
                $p = Provider::where( 'email', $s['email'] )->firstOrFail();
            }
            $out[ $s['name'] ] = $p->id;
        }

        return $out;
    }

    private function products( array $taxGroups, Unit $unit, array $categories, callable $log ): int
    {
        /** @var ProductService $service */
        $service = app( ProductService::class );
        $created = 0;
        foreach ( $this->catalog->items() as $item ) {
            if ( Product::where( 'sku', $item['sku'] )->exists() ) {
                continue;
            }
            $service->create( [
                'name' => $item['name'],
                'product_type' => 'product',
                'type' => 'materialized',
                'category_id' => $categories[ $item['category'] ],
                'status' => 'available',
                'stock_management' => 'enabled',
                'sku' => $item['sku'],
                'barcode' => $item['barcode'],
                'barcode_type' => 'ean13',
                'tax_group_id' => $taxGroups[ $item['tax'] ],
                'tax_type' => 'exclusive',
                'description' => $item['description'],
                'units' => [
                    'unit_group' => $unit->group_id,
                    'accurate_tracking' => false,
                    'auto_cogs' => true,
                    'selling_group' => [ [
                        'unit_id' => $unit->id,
                        'sale_price_edit' => $item['price'],
                        'wholesale_price_edit' => round( $item['price'] * 0.85, 2 ),
                        'barcode' => $item['barcode'],
                        'low_quantity' => $item['perishable'] ? 6 : 4,
                        'stock_alert_enabled' => true,
                        'visible' => true,
                    ] ],
                ],
            ] );
            $created++;
        }
        $log( "products: $created created, " . Product::count() . ' total' );

        return Product::count();
    }

    /** @return array<string,User> username => user */
    public function staff(): array
    {
        /** @var UsersService $users */
        $users = app( UsersService::class );
        $out = [];
        foreach ( $this->catalog->data['staff'] as $s ) {
            $user = User::where( 'username', $s['username'] )->first();
            if ( ! $user ) {
                $user = new User;
                $user->username = $s['username'];
                $user->email = "{$s['username']}@harborandpine.example";
                $user->first_name = $s['first'];
                $user->last_name = $s['last'];
                // Staff exist for attribution only: a random, discarded password nobody knows.
                $user->password = Hash::make( Str::random( 48 ) );
                $user->active = true;
                $user->author_id = Auth::id();
                $user->save();
                $roleNs = $s['role'] === 'store manager' ? 'nexopos.store.administrator' : 'nexopos.store.cashier';
                $users->setUserRole( $user, [ Role::namespace( $roleNs )->id ] );
                Cache::forget( 'ns-all-permissions-' . $user->id );
            }
            $users->createAttribute( $user ); // theme/language row every NexoPOS layout reads (no-op if present)
            $out[ $s['username'] ] = $user;
        }

        return $out;
    }

    /** @return array<string,int> group name => id */
    private function customerGroups(): array
    {
        /** @var CustomerService $service */
        $service = app( CustomerService::class );
        $out = [];
        foreach ( $this->catalog->data['customers']['groups'] as $g ) {
            $group = CustomerGroup::where( 'name', $g['name'] )->first();
            if ( ! $group ) {
                $service->createGroup( [ 'name' => $g['name'], 'description' => isset( $g['discountPercent'] ) ? "{$g['discountPercent']}% member discount" : 'Occasional and walk-in shoppers' ] );
                $group = CustomerGroup::where( 'name', $g['name'] )->firstOrFail();
            }
            $out[ $g['name'] ] = $group->id;
        }

        return $out;
    }

    private function customers( array $groups, callable $log ): int
    {
        /** @var CustomerService $service */
        $service = app( CustomerService::class );
        $c = $this->catalog->data['customers'];
        $rng = Rng::forKey( 20261118, 'customers' );
        // The anonymous till customer used for walk-in sales.
        $this->ensureCustomer( $service, 'walkin', 'Walk-in', 'Customer', 'walk-in@harborandpine.example', $groups['Walk-in'] );
        $existing = Customer::count();
        $target = $c['registeredCount'] + 1;
        $taken = [];
        for ( $i = 0; $existing < $target && $i < $target * 4; $i++ ) {
            $first = $rng->pick( $c['firstNames'] );
            $last = $rng->pick( $c['lastNames'] );
            $email = strtolower( "$first.$last" ) . ( $rng->chance( 0.3 ) ? $rng->int( 1, 99 ) : '' ) . '@mail.example';
            if ( isset( $taken[ $email ] ) || Customer::where( 'email', $email )->exists() ) {
                continue;
            }
            $taken[ $email ] = true;
            $group = $rng->weighted( array_map( fn( $g ) => [ $g['name'], $g['share'] ], $c['groups'] ) );
            $this->ensureCustomer( $service, 'hp-' . substr( md5( $email ), 0, 10 ), $first, $last, $email, $groups[ $group ] );
            $existing++;
        }
        $log( 'customers: ' . Customer::count() );

        return Customer::count();
    }

    private function ensureCustomer( CustomerService $service, string $username, string $first, string $last, string $email, int $groupId ): void
    {
        if ( Customer::where( 'email', $email )->exists() ) {
            return;
        }
        $service->create( [
            'username' => $username, 'email' => $email, 'password' => Hash::make( Str::random( 40 ) ),
            'first_name' => $first, 'last_name' => $last, 'group_id' => $groupId,
            'phone' => sprintf( '+1 360-555-01%02d', crc32( $email ) % 100 ),
            'address' => null,
        ] );
    }

    /** @return array<string,Register> register name => model */
    public function registers(): array
    {
        $out = [];
        foreach ( $this->catalog->store()['registers'] as $name ) {
            $r = Register::where( 'name', $name )->first();
            if ( ! $r ) {
                $r = new Register;
                $r->name = $name;
                $r->status = Register::STATUS_CLOSED;
                $r->author_id = Auth::id();
                $r->description = "Harbor & Pine Market — $name";
                $r->save();
            }
            $out[ $name ] = $r;
        }

        return $out;
    }
}
