<?php
namespace Modules\HarborPine\Providers;

use Illuminate\Support\ServiceProvider;
use Modules\HarborPine\Http\Middleware\ShowcaseGuard;
use Modules\HarborPine\Services\Catalog;

class HarborPineServiceProvider extends ServiceProvider
{
    public function register()
    {
        $this->app->singleton( Catalog::class, fn() => Catalog::load( dirname( __DIR__ ) . '/Data/catalog.json' ) );
    }

    public function boot()
    {
        // Read-only visitor enforcement on every web and API request.
        $router = $this->app['router'];
        $router->pushMiddlewareToGroup( 'web', ShowcaseGuard::class );
        $router->pushMiddlewareToGroup( 'api', ShowcaseGuard::class );
    }
}
