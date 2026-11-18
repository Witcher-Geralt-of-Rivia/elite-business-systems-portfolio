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
| Returns | ~1.2 % of sales: one item of a paid purchase from the last 30 days, through `refundOrder`; 70 % restocked, 30 % damaged (restocked then written off). On a promotional purchase the returned unit takes its share of the order discount with it (refund = price paid; the last unit takes the rest), because NexoPOS keeps a flat discount on refunded orders |
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
- `php artisan hp:replay-check --days=N` (read-only) recomputes the plan of the last N processed days and
  compares every key, kind and timestamp with the ledger: 0 missing, 0 unexpected and 0 mismatches is the
  evidence that recovery from any watermark reproduces exactly the same business day.

## Backfill and reports

`php artisan hp:backfill --months=12` generates history up to now. NexoPOS normally recomputes the whole day's
dashboard after every order and every accounting line (~50 aggregate queries per sale); during backfill a
`DeferredReportService` (container rebinding, backfill only) defers that, then the real service rebuilds every
day and month chronologically (`ns:report --compute`). Live operation uses NexoPOS's normal per-order updates.

A return turns an older sale from "paid" into "partially refunded", but NexoPOS only recomputes *today's*
report. The engine therefore records the original sale day as stale (option `harborpine_reports_stale_from`,
written in the return's transaction) and the simulator recomputes reports from that day after the run; a crash
in between leaves the marker, so the next tick still does it.

**Lookup indexes.** NexoPOS ships its tables with primary keys only. Migration
`2026_11_18_000002_add_lookup_indexes` adds secondary indexes (`hp_*`) on the columns records are looked up by
(order lines/payments/refunds by order, register history by register/order/payment, stock history by product,
orders by date/customer, …). Indexes only — `down()` restores the upstream schema. Effect on the 12-month
dataset: the 43 integrity checks run in ~30 s instead of ~23 min.

**Correction of returned promotional orders (`hp:repair-refunds`, idempotent).** Before the discount-share rule,
fully returned promotional purchases (23 in the first history) ended at total = −discount and stayed "paid";
NexoPOS then re-recorded their cash change at the refund day's register balance (7 cash orders: register chain
broken) or created a cash-change payout for card orders (16). The command withdraws the promotion of those
orders and lets `refreshOrder()` settle them (total 0, "refunded") without re-firing order listeners, restores
each cash-change entry to the change given at the sale (ledger), removes the spurious payouts and gives that
amount back to the rest of the session (closing count included), then recomputes reports from the first
affected day. Refund amounts, payments and stock movements are unchanged.

## Live operation

`hp:worker` (Windows service `portfolio-pos-sim`): every 60 s processes the events that became due; one active
worker (MariaDB `GET_LOCK`); exits after 120 min or 192 MB with code 3 so the service wrapper's failure action
restarts it (a clean 0 would stop a WinSW service); `php artisan hp:sim pause|resume|status`; health at
`/harborpine/health` (paused, worker running, watermark, lag). While paused the watermark stays; on resume the due
events run with their business times. After each processed day the month report is recomputed explicitly (NexoPOS's
own month refresh did not land during simulated runs).

## Integrity (`Services/Integrity.php`, `php artisan hp:integrity`)

43 SQL checks, each returning the number of violating rows (all must be 0): inventory vs. stock history (last
movement, chain continuity, arithmetic, negatives), purchases vs. receipts, order subtotal/total/tax/payment
arithmetic, refunds vs. original lines and order status, register balance chain, reconciled closings and logged
payments, dashboard days vs. orders, months vs. days, duplicates (SKU, barcode, ledger entities), chronology
(lines/payments/refunds vs. order time, sales vs. ledger time, nothing sold before first receipt, products and
customers created before their first sale), and
application-level references. The command also prints record counts and money reconciliation.

## Visitor access (`hp:showcase enable`)

A `harborpine.showcase` role with read permissions (dashboards, catalogue, orders, customers, registers, reports)
plus the POS screen. Visitors enter through `/showcase/enter` (no credentials; rate-limited; only while enabled).
`ShowcaseGuard` refuses every visitor write; submitting an order from the POS screen returns
"Checkout preview: … not saved" so the cashier workflow can be explored without touching the shared database;
settings, modules, users, profile and media are refused; pages carry a read-only banner.

- **POS screen for visitors:** NexoPOS asks the signed-in user for an opened register before selling; opening one
  is a write, so `GET api/cash-registers/used` answers visitors with the first register marked "(preview)". All
  register actions stay refused. Read-only POSTs that NexoPOS uses for reports and searches are allow-listed.
- **Account shape:** the visitor gets NexoPOS's user-attribute row and default dashboard widgets (normally created
  on account activation); its password is random and rotated on every `hp:showcase enable`.
- **Evidence:** `run-pos-e2e.ps1 -Mode visitor` completes a sale on the POS screen (refused with the preview
  message) and then asserts in the database that the visitor authored no orders, register entries, stock
  movements or products.
- **Background calls:** onboarding tours (`POST api/user/guides`) are answered with an empty list for visitors.
  They could not dismiss a tour, since that is a write, so it would reappear on every page. The vendor
  marketplace API and OAuth pages are also refused for visitors (upstream already restricts them by permission).

## Upstream behaviour adjusted by the module (no core patches)

| Upstream behaviour | Effect on the public demo | Module change |
|---|---|---|
| `ResponseReadyEventListener` deletes the cached "installed" flag after every API/dashboard response. `Helper::installed()` then reads it with `has()` followed by `get()` | Under concurrent requests the flag can vanish between the two reads. The request is redirected to `/do-setup`; on the POS screen the catalogue came back empty. App boot can also fail in `ModulesService`, because its options are skipped by the first check and used after the second | The listener is replaced in `app->booted()` with the same permission-cache clearing, minus the deletion. `InstalledState` (container binding for `InstalledStateMiddleware`) confirms a "not installed" answer with the database before redirecting, and logs `installed-state cache race avoided` |
| Daily telemetry (`POST api/system/telemetry`) sends the version, the enabled modules and the request host name to the vendor | The host name contains the server address | `NoTelemetry` answers signed-in calls locally and records the time, so the footer script stays quiet for a day. Anonymous calls still get 401 |
| `public/lang` is a junction to `<app>/lang` | Caddy follows it with the target's permissions; `/lang/en.json` fell through to Laravel (404) | `configure-pos-app.ps1` grants the Caddy service read access to `<app>/lang` (translation JSON only) |
| API rate limit (NexoPOS `ThrottleMiddelware`, 80 requests/min) answers with HTTP 500 "Too Many Attempts" instead of 429 | Normal browsing stays well below the limit; bursts get an error message | Kept: the limit protects the shared demo. The wrong status code is noted, not patched |

## Presentation (`hp:presentation`, idempotent)

- **Artwork:** original vector artwork (`apps/pos/scripts/generate-artwork.py`: category colour, one of 22 simple
  product-form shapes, three shades) published from the module's `Public/` folder and attached through
  `ProductCategory.preview_url` and featured `ProductGallery` rows.
- **Display options:** symbol currency (`$12.49`) and the walk-in customer as the POS default customer.
- **Chronology (once):** the setup command runs on the real clock, so catalogue, supplier, register and customer
  records carried the build time while trading starts a year earlier. Setup records are re-dated into the three
  weeks before opening, each registered customer 0–25 days before their first purchase (seeded), customers
  without purchases across the trading period. Only those timestamps change; two integrity checks keep it true.
