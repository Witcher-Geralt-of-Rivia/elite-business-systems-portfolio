<?php
namespace Modules\HarborPine\Providers;

use App\Classes\Cache;
use App\Events\ResponseReadyEvent;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\ServiceProvider;
use Modules\HarborPine\Http\Middleware\InstalledState;
use Modules\HarborPine\Http\Middleware\NoTelemetry;
use Modules\HarborPine\Http\Middleware\ShowcaseGuard;
use Modules\HarborPine\Services\Catalog;

class HarborPineServiceProvider extends ServiceProvider
{
    public function register()
    {
        $this->app->singleton( Catalog::class, fn() => Catalog::load( dirname( __DIR__ ) . '/Data/catalog.json' ) );
        // Race-free installed-state check (see InstalledState); the router resolves middleware through the container.
        $this->app->bind( \App\Http\Middleware\InstalledStateMiddleware::class, InstalledState::class );
    }

    public function boot()
    {
        // Read-only visitor enforcement on every web and API request.
        $router = $this->app['router'];
        // Telemetry opt-out first, so it applies to every session (visitors are refused POSTs anyway).
        $router->pushMiddlewareToGroup( 'api', NoTelemetry::class );
        $router->pushMiddlewareToGroup( 'web', ShowcaseGuard::class );
        $router->pushMiddlewareToGroup( 'api', ShowcaseGuard::class );

        // Upstream's ResponseReadyEventListener deletes the cached "installed" flag at the end of every API and
        // dashboard response. Concurrent requests then read it between has() and get() as missing: requests
        // were sent to /do-setup, and app boot failed in ModulesService (options not loaded). Replace that
        // listener with the same behaviour minus the deletion; the flag keeps upstream's own 60 s lifetime.
        // Upstream's listeners are registered after module providers boot, hence the booted() callback.
        $this->app->booted( function () {
            Event::forget( ResponseReadyEvent::class );
            Event::listen( ResponseReadyEvent::class, function () {
                if ( Auth::check() ) {
                    Cache::forget( 'ns-all-permissions-' . Auth::id() );
                }
            } );
        } );
    }
}
