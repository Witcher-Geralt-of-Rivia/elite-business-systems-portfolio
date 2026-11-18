# POS data engine — Harbor & Pine Market

Synthetic but **operationally consistent** retail activity for NexoPOS, implemented as the NexoPOS module
`apps/pos/modules/HarborPine` (GPL-3.0). Every record is created by NexoPOS's own services —
`ProductService`, `ProcurementService`, `OrdersService` (sales and refunds), `CashRegistersService`,
`CustomerService` — so stock, accounting, register balances and reports follow from real transactions.
Independent from the CRM engine: its own catalogue, rules, seed and code.

Internals it relies on: [POS_NEXOPOS_INTERNALS.md](POS_NEXOPOS_INTERNALS.md).

## Store

*Harbor & Pine Market* — fictional specialty grocer and home-goods shop in a fictional Pacific Northwest
harbour town; two registers (Front Counter, Café Counter); open 8–20 (Fri/Sat to 21, Sun 9–18); closed on four
holidays. All brands, suppliers, people, addresses (`.example`) and phone numbers (`555-01xx`) are invented.

## Curated source values (`Data/catalog.json`)

12 categories (tax class, markup range, popularity, perishability) · 88 SKUs from 76 products × size variants
with cost, brand, form and description · 30 brands · 11 suppliers (categories, lead time, delivery cadence,
terms) · 5 staff (role, register, shift share, speed) · 70 customer names, 3 customer groups (walk-in, Harbor
Club 5 %, café accounts 10 %) · promotions (seasonal codes) · demand curves (weekday, month, hour, basket sizes,
payment mix, return rate, growth) · return reasons · adjustment reasons.

Derived deterministically: SKU `CAT-BRA-NNNN`, in-store EAN-13 with a valid check digit, shelf price =
cost × category markup rounded to .49/.99, unique company of each SKU's supplier.

## Model (`Services/RetailEngine.php`)

| Process | Rule |
|---|---|
| Deliveries | each supplier on its cadence before opening; quantity = days of cover × expected daily demand − stock on hand, in case packs; skipped when stock suffices; paid and delivered (stock increases through NexoPOS's procurement listener) |
| Registers | each register opens with a float (Front $200, Café $150) by the cashier on shift, closes after hours at the counted balance (reconciled) |
| Sales | Poisson count per day = base 64 × weekday × month seasonality × growth; times follow the hourly traffic curve; register 72 % front / 28 % café; cashier by shift share; basket size distribution; products by popularity (gift/candle peak in Nov–Dec, drinks in summer, café counter favours food & drink); out-of-stock items are skipped |
| Customers | 38 % identified (power-law: a loyal core visits often), else the walk-in till customer |
| Discounts | member group discount (5 % / 10 %), otherwise seasonal promotions when the basket qualifies; sent as the rounded amount so NexoPOS totals match to the cent |
| Tax | 8.9 % on general merchandise, groceries exempt; computed on the discounted taxable amount; order is tax-exclusive |
| Payment | 78 % simulated card (exact amount), 22 % cash (tendered rounded up to a note, change recorded in the register) |
| Returns | ~1.2 % of sales: one item of a paid purchase from the last 30 days, through `refundOrder`; 70 % restocked, 30 % damaged (restocked then written off) |
| Adjustments | Mondays: perishable waste (2–6 % of stock, `defective`); first Monday of the month: shrink / count correction on a quarter of the long-life SKUs |

## Determinism, idempotency, recovery

- Each store day's events are planned from `Rng::forKey(seed, date)`; each event's own decisions use
  `Rng::forKey(seed, event key)`. The plan for a day never depends on which events already ran.
- Every event has a stable key (`2026-03-14:sale:042`) recorded in `harborpine_sim_ledger` **in the same database
  transaction** as the records it creates (unique index). A replay, a restart, a crash mid-day or a second worker
  can never duplicate a sale, delivery or refund.
- `harborpine_sim_state.processed_until` is the watermark; backfill and live operation both resume from it.
- Both NexoPOS clocks are driven per event: `Carbon::setTestNow` (row timestamps) and `ns()->date->define`
  (day reports), in the store time zone.

## Backfill and reports

`php artisan hp:backfill --months=12` generates history up to now. NexoPOS normally recomputes the whole day's
dashboard after every order and every accounting line (~50 aggregate queries per sale); during backfill a
`DeferredReportService` (container rebinding, backfill only) defers that, then the real service rebuilds every
day and month chronologically (`ns:report --compute`). Live operation uses NexoPOS's normal per-order updates.

## Live operation

`hp:worker` (Windows service `portfolio-pos-sim`): every 60 s processes the events that became due; one active
worker (MariaDB `GET_LOCK`); exits after 120 min or 192 MB and is restarted by the service wrapper (bounded
resources); `php artisan hp:sim pause|resume|status`.

## Integrity (`Services/Integrity.php`, `php artisan hp:integrity`)

41 SQL checks, each returning the number of violating rows (all must be 0): inventory vs. stock history (last
movement, chain continuity, arithmetic, negatives), purchases vs. receipts, order subtotal/total/tax/payment
arithmetic, refunds vs. original lines and order status, register balance chain, reconciled closings and logged
payments, dashboard days vs. orders, months vs. days, duplicates (SKU, barcode, ledger entities), chronology
(lines/payments/refunds vs. order time, sales vs. ledger time, nothing sold before first receipt), and
application-level references. The command also prints record counts and money reconciliation.

## Visitor access (`hp:showcase enable`)

A `harborpine.showcase` role with read permissions (dashboards, catalogue, orders, customers, registers, reports)
plus the POS screen. Visitors enter through `/showcase/enter` (no credentials; rate-limited; only while enabled).
`ShowcaseGuard` refuses every visitor write; submitting an order from the POS screen returns
"Checkout preview: … not saved" so the cashier workflow can be explored without touching the shared database;
settings, modules, users, profile and media are refused; pages carry a read-only banner.
