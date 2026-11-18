<?php
namespace Modules\HarborPine\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Symfony\Component\HttpFoundation\Response;

/**
 * Opts this installation out of NexoPOS's daily telemetry without patching the core.
 *
 * Upstream injects a footer script (at most once every 24 h, driven by the option `ns_telemetry_last_sent`)
 * that calls POST /api/system/telemetry; the controller then posts the version, the enabled modules and the
 * request host name to my.nexopos.com. On this demo the host name contains the server address, so the
 * request is answered locally and nothing leaves the server. Recording the time keeps the footer script
 * from being injected again for a day.
 */
class NoTelemetry
{
    public function handle( Request $request, Closure $next ): Response
    {
        // Anonymous calls fall through to the route's own authentication (401); nothing is written for them.
        if ( $request->isMethod( 'POST' ) && trim( $request->path(), '/' ) === 'api/system/telemetry'
            && ( Auth::check() || Auth::guard( 'sanctum' )->check() ) ) {
            ns()->option->set( 'ns_telemetry_last_sent', now()->toDateTimeString() );

            return response()->json( [ 'status' => 'success', 'message' => 'Telemetry is disabled on this installation.' ] );
        }

        return $next( $request );
    }
}
