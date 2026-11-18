<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;

/**
 * Secondary indexes on the NexoPOS columns the store looks records up by. Upstream ships these tables with
 * primary keys only, so every "lines of this order", "history of this register" or "payments of this order"
 * lookup scans the whole table; with a year of trading history that dominates the cost of a sale and of
 * most dashboard pages. Indexes only: no column, constraint or data changes, so down() restores the
 * upstream schema exactly. Named with an hp_ prefix and created only when missing.
 */
return new class extends Migration
{
    private const INDEXES = [
        'nexopos_orders' => [ 'created_at', 'customer_id', 'register_id', 'payment_status' ],
        'nexopos_orders_products' => [ 'order_id', 'product_id' ],
        'nexopos_orders_payments' => [ 'order_id' ],
        'nexopos_orders_refunds' => [ 'order_id' ],
        'nexopos_orders_products_refunds' => [ 'order_id', 'order_refund_id', 'order_product_id' ],
        'nexopos_orders_taxes' => [ 'order_id' ],
        'nexopos_orders_addresses' => [ 'order_id' ],
        'nexopos_orders_coupons' => [ 'order_id' ],
        'nexopos_registers_history' => [ 'register_id,id', 'order_id', 'payment_id' ],
        'nexopos_products_histories' => [ 'product_id,unit_id', 'order_product_id', 'procurement_product_id', 'created_at' ],
        'nexopos_products_histories_combined' => [ 'product_id,unit_id,date' ],
        'nexopos_products_unit_quantities' => [ 'product_id,unit_id' ],
        'nexopos_procurements_products' => [ 'procurement_id', 'product_id' ],
        'nexopos_dashboard_days' => [ 'range_starts' ],
        'nexopos_users_roles_relations' => [ 'user_id' ],
        'nexopos_transactions_histories' => [ 'created_at' ],
        'nexopos_customers_account_history' => [ 'customer_id' ],
    ];

    public function up()
    {
        foreach ( $this->indexes() as [ $table, $name, $columns ] ) {
            if ( ! $this->exists( $table, $name ) ) {
                DB::statement( sprintf( 'CREATE INDEX `%s` ON `%s` (%s)', $name, $table, implode( ',', array_map( fn( $c ) => "`$c`", $columns ) ) ) );
            }
        }
    }

    public function down()
    {
        foreach ( $this->indexes() as [ $table, $name ] ) {
            if ( $this->exists( $table, $name ) ) {
                DB::statement( sprintf( 'DROP INDEX `%s` ON `%s`', $name, $table ) );
            }
        }
    }

    /** @return array<int, array{string,string,array<int,string>}> only tables/columns present in this install */
    private function indexes(): array
    {
        $out = [];
        foreach ( self::INDEXES as $table => $sets ) {
            $present = collect( DB::select( 'SELECT column_name AS c FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ?', [ $table ] ) )
                ->map( fn( $r ) => $r->c )->all();
            foreach ( $sets as $set ) {
                $columns = explode( ',', $set );
                if ( array_diff( $columns, $present ) ) {
                    continue;
                }
                $out[] = [ $table, 'hp_' . substr( md5( $table . ':' . $set ), 0, 10 ), $columns ];
            }
        }

        return $out;
    }

    private function exists( string $table, string $name ): bool
    {
        return (bool) DB::selectOne( 'SELECT 1 AS x FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? LIMIT 1', [ $table, $name ] );
    }
};
