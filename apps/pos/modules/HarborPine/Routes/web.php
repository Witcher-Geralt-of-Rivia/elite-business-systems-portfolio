<?php
use Carbon\Carbon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;
use Modules\HarborPine\Services\Catalog;
use Modules\HarborPine\Services\Showcase;

// Read-only visitor entry: no credentials; available only while showcase mode is enabled.
Route::get( '/showcase/enter', function () {
    abort_unless( Showcase::enabled(), 404 );
    $visitor = Showcase::user();
    abort_unless( $visitor !== null, 404 );
    Auth::login( $visitor );
    request()->session()->regenerate();

    return redirect( '/dashboard' );
} )->middleware( 'throttle:10,1' )->name( 'harborpine.showcase.enter' );

// Operational health for monitoring and the portfolio portal: no business figures, no authentication.
Route::get( '/harborpine/health', function () {
    try {
        $state = DB::table( 'harborpine_sim_state' )->where( 'id', 1 )->first();
        $worker = DB::selectOne( "select is_used_lock('harborpine-sim-worker') as w" )->w !== null;
    } catch ( \Throwable $e ) {
        return response()->json( [ 'status' => 'error', 'database' => false ], 503 )->header( 'Cache-Control', 'no-store' );
    }
    $tz = app( Catalog::class )->store()['timezone'];
    $lag = $state ? max( 0, Carbon::parse( $state->processed_until, $tz )->diffInSeconds( Carbon::now( $tz ), false ) ) : null;

    return response()->json( [
        'status' => 'ok',
        'database' => true,
        'simulation' => $state ? [
            'paused' => (bool) $state->paused,
            'worker_running' => $worker,
            'processed_until' => Carbon::parse( $state->processed_until, $tz )->toIso8601String(),
            'lag_seconds' => (int) $lag,
        ] : null,
    ] )->header( 'Cache-Control', 'no-store' );
} )->middleware( 'throttle:60,1' )->name( 'harborpine.health' );
