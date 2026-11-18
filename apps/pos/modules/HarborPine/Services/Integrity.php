<?php
namespace Modules\HarborPine\Services;

use Illuminate\Support\Facades\DB;

/**
 * Data-integrity checks for the Harbor & Pine Market dataset. Each check is one SQL query returning
 * the number of violating rows; a consistent dataset returns 0 for every check.
 * Amount comparisons allow 0.01 for currency rounding.
 */
class Integrity
{
    /** Stock movement sign per NexoPOS ProductHistory operation type. */
    private const INCREASE = "'procured','returned','added','incoming-transfer','convert-in','transfer-rejected','transfer-canceled','void-return'";

    private const DECREASE = "'sold','defective','lost','removed','outgoing-transfer','convert-out','deleted'";

    public static function checks(): array
    {
        $inc = self::INCREASE;
        $dec = self::DECREASE;

        return [
            // ---- inventory versus transaction history
            'stock_differs_from_last_history' => "select count(*) from nexopos_products_unit_quantities uq
                join (select product_id, unit_id, max(id) as last_id from nexopos_products_histories group by product_id, unit_id) h
                  on h.product_id = uq.product_id and h.unit_id = uq.unit_id
                join nexopos_products_histories ph on ph.id = h.last_id
                where abs(uq.quantity - ph.after_quantity) > 0.0001",
            'history_chain_broken' => "select count(*) from (
                select before_quantity, lag(after_quantity) over (partition by product_id, unit_id order by id) as prev_after
                from nexopos_products_histories) x where prev_after is not null and abs(before_quantity - prev_after) > 0.0001",
            'history_arithmetic_wrong' => "select count(*) from nexopos_products_histories
                where (operation_type in ($inc) and abs(after_quantity - (before_quantity + quantity)) > 0.0001)
                   or (operation_type in ($dec) and abs(after_quantity - (before_quantity - quantity)) > 0.0001)",
            'negative_stock' => "select count(*) from nexopos_products_unit_quantities where quantity < 0",
            'stock_without_history' => "select count(*) from nexopos_products_unit_quantities uq where uq.quantity <> 0
                and not exists (select 1 from nexopos_products_histories h where h.product_id = uq.product_id and h.unit_id = uq.unit_id)",
            // ---- purchases versus stock receipts
            'procurement_line_not_received' => "select count(*) from nexopos_procurements_products pp
                join nexopos_procurements p on p.id = pp.procurement_id and p.delivery_status in ('delivered','stocked')
                where not exists (select 1 from nexopos_products_histories h where h.procurement_product_id = pp.id
                  and h.operation_type = 'procured' and abs(h.quantity - pp.quantity) < 0.0001)",
            'procurement_total_mismatch' => "select count(*) from nexopos_procurements p
                where abs(p.cost - (select coalesce(sum(total_purchase_price),0) from nexopos_procurements_products pp where pp.procurement_id = p.id)) > 0.01",
            // ---- sales versus line items, taxes, payments
            'order_subtotal_vs_lines' => "select count(*) from nexopos_orders o where not exists (select 1 from nexopos_orders_refunds r where r.order_id = o.id)
                and abs(o.subtotal - (select coalesce(sum(total_price),0) from nexopos_orders_products op where op.order_id = o.id)) > 0.01",
            'order_total_arithmetic' => "select count(*) from nexopos_orders o where not exists (select 1 from nexopos_orders_refunds r where r.order_id = o.id)
                and abs(o.total - (o.subtotal - o.discount + o.tax_value)) > 0.01",
            'order_tax_vs_taxable_lines' => "select count(*) from nexopos_orders o where o.subtotal > 0
                and not exists (select 1 from nexopos_orders_refunds r where r.order_id = o.id)
                and abs(o.tax_value - round((select coalesce(sum(op.total_price * coalesce(tr.rate,0) / 100),0)
                      from nexopos_orders_products op left join (select tax_group_id, sum(rate) rate from nexopos_taxes group by tax_group_id) tr
                        on tr.tax_group_id = op.tax_group_id where op.order_id = o.id) * (1 - o.discount / o.subtotal), 2)) > 0.011",
            'paid_order_payments_mismatch' => "select count(*) from nexopos_orders o where o.payment_status = 'paid'
                and (abs((select coalesce(sum(value),0) from nexopos_orders_payments p where p.order_id = o.id) - o.tendered) > 0.01
                  or abs(o.tendered - o.`change` - o.total) > 0.01)",
            'order_without_lines' => "select count(*) from nexopos_orders o where not exists (select 1 from nexopos_orders_products op where op.order_id = o.id)",
            // ---- returns versus original transactions
            'refund_order_missing' => "select count(*) from nexopos_orders_refunds r where not exists (select 1 from nexopos_orders o where o.id = r.order_id)",
            'refund_line_wrong_order' => "select count(*) from nexopos_orders_products_refunds pr join nexopos_orders_products op on op.id = pr.order_product_id where op.order_id <> pr.order_id",
            'refund_line_exceeds_sale' => "select count(*) from nexopos_orders_products_refunds pr join nexopos_orders_products op on op.id = pr.order_product_id where pr.unit_price - op.unit_price > 0.0001 or op.quantity < 0",
            'refund_total_vs_lines' => "select count(*) from nexopos_orders_refunds r where abs(r.total - r.shipping - (select coalesce(sum(total_price),0) from nexopos_orders_products_refunds pr where pr.order_refund_id = r.id)) > 0.01",
            'refunded_order_status' => "select count(*) from nexopos_orders o where exists (select 1 from nexopos_orders_refunds r where r.order_id = o.id) and o.payment_status not in ('refunded','partially_refunded')",
            'refund_restock_missing' => "select count(*) from nexopos_orders_products_refunds pr where not exists (select 1 from nexopos_products_histories h where h.order_product_id = pr.order_product_id and h.operation_type = 'returned')",
            // ---- cash registers
            'register_balance_chain' => "select count(*) from (
                select balance_before, action, lag(balance_after) over (partition by register_id order by id) as prev_after
                from nexopos_registers_history) x
                where prev_after is not null and action <> 'register-opening' and abs(balance_before - prev_after) > 0.01",
            'register_close_not_reconciled' => "select count(*) from nexopos_registers_history where action = 'register-closing' and transaction_type <> 'unchanged'",
            'register_payment_not_logged' => "select count(*) from nexopos_orders_payments p join nexopos_orders o on o.id = p.order_id
                where o.register_id is not null and not exists (select 1 from nexopos_registers_history h where h.payment_id = p.id and h.action = 'register-order-payment')",
            'register_open_after_hours' => "select count(*) from nexopos_registers where status = 'opened'
                and (select max(created_at) from nexopos_registers_history h where h.register_id = nexopos_registers.id and h.action = 'register-opening') < (select max(occurred_at) from harborpine_sim_ledger where kind = 'close_register')",
            // ---- daily and monthly reporting aggregates
            'dashboard_day_paid_vs_orders' => "select count(*) from nexopos_dashboard_days d
                where abs(d.day_paid_orders - (select coalesce(sum(total),0) from nexopos_orders o where o.payment_status = 'paid' and o.created_at between d.range_starts and d.range_ends)) > 0.01
                   or d.day_paid_orders_count <> (select count(*) from nexopos_orders o where o.payment_status = 'paid' and o.created_at between d.range_starts and d.range_ends)",
            'dashboard_day_taxes_vs_orders' => "select count(*) from nexopos_dashboard_days d
                where abs(d.day_taxes - (select coalesce(sum(tax_value),0) from nexopos_orders o where o.payment_status = 'paid' and o.created_at between d.range_starts and d.range_ends)) > 0.01",
            'dashboard_month_vs_days' => "select count(*) from nexopos_dashboard_months m
                where abs(m.month_paid_orders - (select coalesce(sum(day_paid_orders),0) from nexopos_dashboard_days d where d.range_starts >= m.range_starts and d.range_ends <= m.range_ends)) > 0.01",
            'business_day_without_report' => "select count(*) from (select distinct date(occurred_at) d from harborpine_sim_ledger where kind = 'sale' and entity_id is not null) x
                where not exists (select 1 from nexopos_dashboard_days dd where date(dd.range_starts) = x.d)",
            // ---- duplicates and idempotency
            'duplicate_sku' => "select count(*) from (select sku from nexopos_products group by sku having count(*) > 1) x",
            'duplicate_barcode' => "select count(*) from (select barcode from nexopos_products group by barcode having count(*) > 1) x",
            'ledger_entity_reused' => "select count(*) from (select entity, entity_id from harborpine_sim_ledger where entity_id is not null group by entity, entity_id having count(*) > 1 and entity <> 'register') x",
            'ledger_order_missing' => "select count(*) from harborpine_sim_ledger l where l.entity = 'order' and not exists (select 1 from nexopos_orders o where o.id = l.entity_id)",
            // ---- chronology
            'order_line_time_mismatch' => "select count(*) from nexopos_orders_products op join nexopos_orders o on o.id = op.order_id where abs(timestampdiff(second, o.created_at, op.created_at)) > 5",
            'payment_before_order' => "select count(*) from nexopos_orders_payments p join nexopos_orders o on o.id = p.order_id where p.created_at < o.created_at - interval 5 second",
            'refund_before_sale' => "select count(*) from nexopos_orders_refunds r join nexopos_orders o on o.id = r.order_id where r.created_at <= o.created_at",
            'sale_outside_ledger_time' => "select count(*) from harborpine_sim_ledger l join nexopos_orders o on o.id = l.entity_id where l.entity = 'order' and abs(timestampdiff(second, l.occurred_at, o.created_at)) > 5",
            // Setup records and customers are dated before the trading activity that uses them (Chronology).
            'product_created_after_first_sale' => "select count(*) from nexopos_products p where p.created_at > (select min(op.created_at) from nexopos_orders_products op where op.product_id = p.id)",
            'customer_created_after_first_order' => "select count(*) from nexopos_users u where u.created_at > (select min(o.created_at) from nexopos_orders o where o.customer_id = u.id)",
            'sold_before_stocked' => "select count(*) from nexopos_products_histories s where s.operation_type = 'sold'
                and not exists (select 1 from nexopos_products_histories p where p.product_id = s.product_id and p.operation_type = 'procured' and p.id < s.id)",
            // ---- foreign keys (application-level references)
            'fk_order_customer' => "select count(*) from nexopos_orders o where not exists (select 1 from nexopos_users u where u.id = o.customer_id)",
            'fk_order_line_product' => "select count(*) from nexopos_orders_products op where op.product_id is not null and op.product_id > 0 and not exists (select 1 from nexopos_products p where p.id = op.product_id)",
            'fk_payment_order' => "select count(*) from nexopos_orders_payments p where not exists (select 1 from nexopos_orders o where o.id = p.order_id)",
            'fk_history_product' => "select count(*) from nexopos_products_histories h where not exists (select 1 from nexopos_products p where p.id = h.product_id)",
            'fk_procurement_provider' => "select count(*) from nexopos_procurements p where not exists (select 1 from nexopos_providers v where v.id = p.provider_id)",
            'fk_register_history_register' => "select count(*) from nexopos_registers_history h where not exists (select 1 from nexopos_registers r where r.id = h.register_id)",
        ];
    }

    /** @return array<string,int> */
    public static function run(): array
    {
        $out = [];
        foreach ( self::checks() as $name => $sql ) {
            $row = (array) DB::selectOne( $sql );
            $out[ $name ] = (int) array_values( $row )[0];
        }

        return $out;
    }

    /** Record counts and money reconciliation for the report. */
    public static function profile(): array
    {
        $q = fn( string $sql ) => (array) DB::selectOne( $sql );

        return [
            'counts' => $q( "select (select count(*) from nexopos_products) products, (select count(*) from nexopos_providers) suppliers,
                (select count(*) from nexopos_users u join nexopos_users_roles_relations r on r.user_id = u.id join nexopos_roles ro on ro.id = r.role_id and ro.namespace = 'nexopos.store.customer') customers,
                (select count(*) from nexopos_orders) orders, (select count(*) from nexopos_orders_products) order_lines,
                (select count(*) from nexopos_orders_payments) payments, (select count(*) from nexopos_orders_refunds) refunds,
                (select count(*) from nexopos_procurements) procurements, (select count(*) from nexopos_products_histories) stock_movements,
                (select count(*) from nexopos_registers_history where action = 'register-opening') register_sessions,
                (select count(*) from nexopos_dashboard_days) report_days, (select count(*) from nexopos_dashboard_months) report_months,
                (select count(*) from harborpine_sim_ledger) ledger_events" ),
            'money' => $q( "select round(sum(case when payment_status = 'paid' then total end),2) paid_sales,
                round(sum(tax_value),2) taxes, round(sum(discount),2) discounts,
                round((select sum(total) from nexopos_orders_refunds),2) refunds,
                round((select sum(cost) from nexopos_procurements),2) purchases_at_cost,
                round((select sum(day_paid_orders) from nexopos_dashboard_days),2) dashboard_paid_sales,
                round((select sum(value) from nexopos_orders_payments where identifier = 'cash-payment'),2) cash_tendered,
                round((select sum(value) from nexopos_orders_payments where identifier = 'card-payment'),2) card_payments
                from nexopos_orders" ),
            'range' => $q( "select min(created_at) first_order, max(created_at) last_order, count(distinct date(created_at)) trading_days from nexopos_orders" ),
        ];
    }
}
