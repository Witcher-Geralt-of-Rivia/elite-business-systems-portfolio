<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up()
    {
        // Singleton: scenario parameters and live-worker control.
        if ( ! Schema::hasTable( 'harborpine_sim_state' ) ) {
            Schema::create( 'harborpine_sim_state', function ( Blueprint $table ) {
                $table->unsignedTinyInteger( 'id' )->primary();
                $table->unsignedBigInteger( 'seed' );
                $table->date( 'scenario_start' );
                $table->dateTime( 'processed_until' );     // simulated time fully processed (UTC)
                $table->boolean( 'paused' )->default( false );
                $table->decimal( 'intensity', 5, 2 )->default( 1 );
                $table->json( 'stats' )->nullable();
                $table->timestamps();
            } );
        }
        // Idempotency ledger: one row per business event, written in the same DB transaction as
        // the records the event creates. A replayed event finds its key and is skipped.
        if ( ! Schema::hasTable( 'harborpine_sim_ledger' ) ) {
            Schema::create( 'harborpine_sim_ledger', function ( Blueprint $table ) {
                $table->id();
                $table->string( 'event_key', 80 )->unique();
                $table->string( 'kind', 30 )->index();
                $table->dateTime( 'occurred_at' )->index();   // store-local business time
                $table->string( 'entity', 30 )->nullable();
                $table->unsignedBigInteger( 'entity_id' )->nullable();
                $table->json( 'details' )->nullable();
                $table->dateTime( 'recorded_at' );
            } );
        }
    }

    public function down()
    {
        Schema::dropIfExists( 'harborpine_sim_ledger' );
        Schema::dropIfExists( 'harborpine_sim_state' );
    }
};
