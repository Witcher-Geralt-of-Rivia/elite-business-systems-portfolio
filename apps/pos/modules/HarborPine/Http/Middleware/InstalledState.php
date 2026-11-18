<?php
namespace Modules\HarborPine\Http\Middleware;

use App\Events\InstalledStateBeforeCheckedEvent;
use App\Http\Middleware\InstalledStateMiddleware;
use App\Services\Helper;
use Closure;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Schema;

/**
 * Replaces NexoPOS's InstalledStateMiddleware (container binding, no core patch) to remove a race that sent
 * live requests to the installer.
 *
 * Upstream caches "installed" under `ns-core-installed` and reads it back with Cache::has() then Cache::get().
 * The flag is also deleted at the end of every API/dashboard response (ResponseReadyEventListener) and after
 * every artisan command (CommandFinishedListener). Under concurrent requests, another response can delete it
 * between has() and get(); get() returns null and the request is redirected to /do-setup. On the POS screen,
 * that left the catalog empty ("no products and no categories"). Measured on 2026-11-18: 1 in 348 parallel
 * API calls, and 2 in about 3,000 browser-test requests.
 *
 * Behaviour is unchanged when upstream says "installed". Otherwise the database is asked directly, using the
 * same check upstream caches, before redirecting. A real "not installed" state still goes to the installer.
 */
class InstalledState extends InstalledStateMiddleware
{
    public function handle( $request, Closure $next )
    {
        InstalledStateBeforeCheckedEvent::dispatch( $next, $request );

        if ( Helper::installed() || $this->databaseInstalled() ) {
            return $next( $request );
        }

        return redirect()->route( 'ns.do-setup' );
    }

    private function databaseInstalled(): bool
    {
        try {
            $installed = Schema::hasTable( 'nexopos_options' );
            if ( $installed ) {
                // Rare by design; logged so the race stays observable (operations log, not an error).
                Log::warning( 'HarborPine: installed-state cache race avoided', [ 'path' => request()->path() ] );
            }

            return $installed;
        } catch ( \Throwable $e ) {
            return false;
        }
    }
}
