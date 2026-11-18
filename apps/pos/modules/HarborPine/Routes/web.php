<?php
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Route;
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
