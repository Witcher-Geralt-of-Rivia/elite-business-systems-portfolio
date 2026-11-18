<?php
namespace Modules\HarborPine\Services;

use App\Models\Permission;
use App\Models\Role;
use App\Models\User;
use App\Services\Options;
use App\Services\UserOptions;
use App\Services\UsersService;
use App\Services\WidgetService;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;

/**
 * Read-only visitor access for the portfolio. The visitor account has a random, discarded password
 * (it cannot sign in with credentials); visitors enter only through /showcase/enter, and only while
 * the option `harborpine_showcase` is "yes". All visitor writes are refused by ShowcaseGuard.
 */
class Showcase
{
    public const ROLE = 'harborpine.showcase';

    public const EMAIL = 'visitor@showcase.harborandpine.example';

    public const OPTION = 'harborpine_showcase';

    /** Read permissions a visitor needs (docs/POS_NEXOPOS_INTERNALS.md §8) + the POS screen for the checkout preview. */
    public const PERMISSIONS = [
        'read.dashboard',
        'nexopos.see.sale-card-widget', 'nexopos.see.incomplete-sale-card-widget', 'nexopos.see.expense-card-widget',
        'nexopos.see.orders-chart-widget', 'nexopos.see.orders-summary-widget', 'nexopos.see.best-customers-widget', 'nexopos.see.best-cashier-widget',
        'nexopos.read.products', 'nexopos.read.products-history', 'nexopos.read.products-units', 'nexopos.read.categories',
        'nexopos.read.taxes', 'nexopos.read.providers', 'nexopos.read.procurements',
        'nexopos.read.orders', 'nexopos.read.customers', 'nexopos.read.customers-groups', 'nexopos.read.coupons', 'nexopos.read.rewards',
        'nexopos.read.registers', 'nexopos.read.registers-history',
        'nexopos.reports.sales', 'nexopos.reports.products-report', 'nexopos.reports.best_sales', 'nexopos.reports.yearly',
        'nexopos.reports.customers', 'nexopos.reports.inventory', 'nexopos.reports.low-stock', 'nexopos.reports.stock-history',
        'nexopos.reports.payment-types', 'nexopos.reports.customers-statement', 'nexopos.reports.transactions',
        'nexopos.pos.access', 'nexopos.pos.read-products',
    ];

    public static function enabled(): bool
    {
        return ns()->option->get( self::OPTION ) === 'yes';
    }

    public static function isVisitor( $user ): bool
    {
        return $user !== null && ( $user->email ?? null ) === self::EMAIL;
    }

    public static function user(): ?User
    {
        return User::where( 'email', self::EMAIL )->first();
    }

    /** Creates/refreshes the role and the visitor account and sets the enable flag. */
    public static function configure( bool $enable ): array
    {
        $role = Role::firstOrNew( [ 'namespace' => self::ROLE ] );
        $role->name = 'Portfolio visitor (read-only)';
        $role->description = 'Read-only showcase access: dashboards, catalog, orders, registers and reports; the checkout preview never saves.';
        $role->locked = true;
        $role->save();
        $existing = Permission::whereIn( 'namespace', self::PERMISSIONS )->pluck( 'namespace' )->all();
        $role->addPermissions( $existing );

        $user = self::user();
        if ( ! $user ) {
            $user = new User;
            $user->email = self::EMAIL;
            $user->first_name = 'Guest';
            $user->last_name = 'Visitor';
            $user->active = true;
            $user->author_id = StoreBuilder::admin()->id;
        }
        $user->username = 'guest'; // shown in the header ("Howdy, guest")
        // Rotated on every configure and never stored: entry is only via /showcase/enter.
        $user->password = Hash::make( Str::random( 64 ) );
        $user->save();
        app( UsersService::class )->setUserRole( $user, [ $role->id ] );
        Cache::forget( 'ns-all-permissions-' . $user->id );
        $user = $user->fresh();
        app( UsersService::class )->createAttribute( $user ); // theme/language row the layouts require
        // NexoPOS seeds dashboard widgets on account activation, which the visitor never goes through.
        app( WidgetService::class )->addDefaultWidgetsToAreas( $user );
        // Upstream product notices ("Learn more", module store) are not part of the store being shown:
        // the visitor account keeps NexoPOS's own "snooze ads" preference, without expiry.
        ( new UserOptions( $user->id ) )->set( 'snooze_ads_24h', 'yes' );
        app( Options::class )->set( self::OPTION, $enable ? 'yes' : 'no' );

        return [ 'enabled' => $enable, 'permissions' => count( $existing ), 'missing' => array_values( array_diff( self::PERMISSIONS, $existing ) ), 'user_id' => $user->id ];
    }
}
