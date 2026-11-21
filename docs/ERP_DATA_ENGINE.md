# ERP data engine — Sable Ridge Electronics Supply Co.

**Status (2026-11-19):** the custom Frappe app `portfolio_sim` is implemented in `apps/erp/portfolio_sim`.
- **Linux:** its ERPNext integration tests **pass on real Frappe/ERPNext v16.60.0 on Linux** (GitHub Actions, 7/7,
  3,068 events, 36 integrity checks at 0, replay exact).
- **Windows host (2026-11-20, D-019):** ERPNext runs **natively on Windows, privately** (127.0.0.1 only) as Windows
  services ([runbooks/ERP_NATIVE_WINDOWS.md](runbooks/ERP_NATIVE_WINDOWS.md)); browser tests exist and pass. Public
  HTTPS needs a separate owner approval. WSL1 and QEMU routes are closed.
- **Concurrency (R-018):** with the scheduler on, ERPNext's own stock revaluation job can deadlock with an event; the
  engine retries such an event after a full rollback (up to 5 attempts).

Integrity: 36 checks. The 32 described below plus four value checks (zero-rate order/purchase lines, zero-value
invoices/bills) added after the Linux runs showed that a zero-priced history is internally consistent.

## Scenario (independent of the CRM and POS)

*Sable Ridge Electronics Supply Co.* is a fictional B2B wholesale electronics distributor in Columbus, Ohio.

| Area | Content |
|---|---|
| Warehouses | Columbus Distribution Center, Cleveland and Cincinnati branches, Returns and Inspection |
| Catalogue | 96 items in 12 groups (cable, connectors, power, batteries, circuit protection, LED lighting, networking, enclosures, tools, test and measurement, passive components, thermal) with cost, list price (group margin), pack size and demand weight |
| Suppliers | 12 fictional manufacturers and distributors, each with terms (Net 30–60), lead times, fill rate and a weekly review day |
| Customers | 150 in six segments (electrical contractors, IT and AV integrators, repair shops, OEM manufacturers, facilities, resellers) across four territories. Each has terms, a discount, an order rate and payment behaviour (on-time share, lateness, installments, weekly batch payer, monthly advance payer). Resellers and institutions are tax-exempt, as are out-of-state customers |
| Staff | 24 employees in five departments; 6 account managers act as Sales Persons covering territories |
| Accounting | ERPNext "Standard" chart; Ohio sales tax 7.5 % (simulated combined rate); opening capital and opening stock; monthly leases, payroll, utilities, telecom, freight, marketing, travel, maintenance, bank fees |

Curated source values: `apps/erp/portfolio_sim/portfolio_sim/data/catalog.json`, **497** strings (test range 450–650):
- names and descriptions;
- item feature phrases, combined into item descriptions;
- shipping instructions and purchase notes, used as order remarks;
- return reasons, contact titles and supplier cities.

## Model (`engine/planner.py`)

Each business day follows a fixed order, and every step emits dated events with stable keys
(`<date>:<kind>:<n>`).

| Time | Process |
|---|---|
| 07:00 | opening (first day only): capital journal, opening stock at cost (Stock Reconciliation "Opening Stock"), Temporary Opening cleared to Opening Balance Equity |
| 08:00 | receipts of due purchase orders. Partial fills follow the supplier's fill rate; the remainder arrives 3–8 business days later |
| 08:30 | purchase returns of defects found on inspection: receipt return plus debit note |
| 09:00 | Tuesday branch replenishment (target 12 days of branch demand plus backorders); Friday restock of inspected returns to the DC |
| 09:30 | deliveries of open sales orders from the customer's warehouse. Lines without stock stay backordered. Each delivery is invoiced immediately |
| 11:00 | supplier invoices, 1–6 business days after a receipt |
| 09:40–16:30 | new sales orders: Poisson count × month seasonality × weekday × 12 %/year growth. Customers are weighted by order rate; lines are chosen by segment–category affinity, category seasonality and item demand weight; quantities are log-normal |
| 12:30 | monthly advances from advance-paying customers |
| 13:00 | customer payments at the planned date. On time pays 0–5 days early; late pays exponentially later. Installments pay half 14 days early and the rest later. Batch payers pay all due invoices in one payment on Wednesdays |
| 14:00 | customer returns 3–20 business days after delivery (5 % of invoices): delivery return to the Returns warehouse, plus a credit note. The credit note reduces the invoice if it is unpaid; otherwise it stands alone and is reconciled later |
| 15:00 | Thursday supplier payment run for bills due within 7 days |
| 16:00 | Friday reconciliation (Payment Reconciliation) of open credits and advances against open invoices |
| 16:30 | month end: advance payers reconciled and their remaining open invoices settled |
| 16:45 | expenses on their monthly days (bank journal entries) |
| 17:00 | purchase orders on each supplier's review day, when stock position falls below the reorder point (lead time + 5 + 10 safety days). Orders top up to lead time + 5 + 30 days of demand, rounded to pack size; rates carry 3.5 %/year inflation |
| 17:30 | last business day of the month: cycle count of six DC items with small shrinkage (Stock Reconciliation) |

The planner keeps its own projection of stock, open orders, payables, receivables and credits, and never reads the
ERP. The projected stock can never go negative (asserted).

**Planned volume** (seed 20261119, 2025-08-01 → 2026-11-18, 331 business days): 26,461 events, planned in 11 s.

| Event kind | Count | Event kind | Count |
|---|---|---|---|
| delivery_note / sales_invoice | 6,266 / 6,266 | purchase_order / receipt / invoice | 567 / 562 / 555 |
| customer_payment | 5,347 | supplier_payment | 505 |
| sales_order | 5,094 (15.4 per business day) | reconcile | 390 |
| sales_return | 311 (5.0 % of invoices) | stock_transfer | 198 |
| expense | 187 | customer_advance / month_end_settlement | 80 / 75 |
| purchase_return | 40 | stock_count | 15 |

Events per month range from 1,114 to 2,054.

## From events to ERPNext documents (`services/executor.py`)

| Event | ERPNext route (functions verified against v16.60.0) |
|---|---|
| purchase_order | new Purchase Order (supplier, rates, schedule) → `submit()` |
| purchase_receipt | `erpnext.buying…purchase_order.make_purchase_receipt` → rows trimmed to the planned quantities → back-dated → submit |
| purchase_invoice | `erpnext.stock…purchase_receipt.make_purchase_invoice` → bill number and date → submit |
| purchase_return | `make_purchase_return` (stock out) plus `purchase_invoice.make_debit_note`, with `update_outstanding_for_self` set when the bill is already paid |
| supplier_payment | `payment_entry.get_payment_entry("Purchase Invoice", …)` → submit |
| sales_order | new Sales Order: Standard Selling price list, customer discount, Ohio tax rows for taxable customers |
| delivery_note | `selling…sales_order.make_delivery_note` → trimmed → back-dated → submit |
| sales_invoice | `stock…delivery_note.make_sales_invoice` → back-dated, payment schedule recomputed from terms → submit |
| customer_payment / month_end_settlement | `get_payment_entry("Sales Invoice", …)` for the first invoice, further invoices added as references (batch payment) |
| customer_advance | new unallocated Payment Entry (Receive) |
| sales_return | `delivery_note.make_sales_return` (stock into Returns and Inspection) plus `sales_invoice.make_sales_return` credit note |
| reconcile | Payment Reconciliation: `get_unreconciled_entries()` → `allocate_entries()` → `reconcile()`; the company setting "Oldest Of Invoice Or Advance" keeps back-dated reconciliations in chronological order |
| stock_transfer / stock_count | Stock Entry (Material Transfer) / Stock Reconciliation. Before a count, ERPNext's quantity must equal the projection, otherwise a `Divergence` stops the run |
| expense / opening | Journal Entry (Bank Entry / Journal Entry / Opening Entry) |

No ledger table is written directly. Back-dating uses ERPNext's own `set_posting_time`, and events run in
chronological order, so no later postings exist when a document is submitted.

## Determinism, idempotency, recovery

- **Seeding:** SplitMix64 streams are derived from (seed, label), with one stream per day. A day's plan depends
  only on the seed and the persisted state. Changing the generator or catalogue changes the pinned first-month hash
  in the tests; that change is never made on a site whose history came from the old plan.
- **Exactly-once:**
  - the planner state and the day's pending events are committed when the day is planned;
  - each event's documents, its `Distribution Sim Event` ledger row (primary key = event key) and the shortened
    pending list are committed in one transaction;
  - an event already in the ledger is skipped, and a `filelock` allows one engine at a time.
- **Recovery:** stopping at any point and running `backfill` again resumes at the first unexecuted event. The engine
  tests prove that resuming from persisted state (fresh process every 9 days) gives the identical plan. The
  ERPNext-side crash test is written (test 07) but not yet executed.
- **Replay check:** `bench --site <site> portfolio-sim replay-check` re-plans from the start and compares keys, kinds
  and dates with the ledger, and the recomputed state with the persisted one.

## Integrity checks (`services/integrity.py`, 32, all must be 0)

| Area | Checks |
|---|---|
| General ledger | GL balanced per voucher and in total; nothing posted after the processed point; nothing on weekends; operating bank account never negative |
| Receivables and payables | Sales and Purchase Invoice outstanding = Payment Ledger sum; Debtors/Creditors GL balance = payment ledger; sales tax = rate × net total; no untaxed invoice for a taxable customer |
| Values (added after the Linux runs) | no zero-rate sales or purchase order lines; no zero-value invoices or bills |
| Inventory | Bin = quantity after the latest Stock Ledger entry (corrected after the Linux runs: Stock Reconciliation entries carry `actual_qty` 0); no negative stock; stock value (SLE) = Stock accounts (GL); ERP quantities = planner projection after each complete day |
| Relationships | no over-delivery or over-receipt; every delivery from a Sales Order, invoice from a Delivery Note, receipt from a Purchase Order, bill from a Purchase Receipt; returns within delivered and received quantities |
| Chronology | delivery ≥ order, receipt ≥ order, invoice ≥ delivery, bill ≥ receipt, payment ≥ invoice |
| Simulation ledger | every submitted transaction document is referenced by the ledger (system-generated reconciliation journals excepted); ledger references exist and are submitted; no document referenced twice; no cancelled ledger entries |

## Owners' funding (added 2026-11-20)

The first complete history (26,598 events, 2025-08-01 → 2026-11-20) failed one integrity check:
`bank_balance_negative_days = 57`. The scenario is not profitable: over 15½ months sales were $2.82M, cost of goods
sold $2.29M (18.6 % gross margin) and operating expenses about $3.1M (salaries $1.92M for 24 staff, rent $0.70M,
freight $0.24M). The $1.4M opening capital ran out at the end of August 2026 and the operating account reached
−$277,583. The Linux CI runs covered only two months and could not show it.

Correction, through ERPNext's own documents and inside the deterministic plan (no SQL change, no regenerated history):
from 2026-08-01 the owners contribute **$200,000 on the first business day of each month** (Journal Entry: operating
bank account to Capital Stock; event kind `capital_contribution`, 07:15). The rule draws no random numbers, so every
other event is unchanged (verified: replay before the amendment showed exactly the 4 new events missing, 26,598
existing events matching, state equal). `portfolio-sim amend` executed those 4 events on their planned dates (exactly
once, ledger primary key); new days include the rule automatically. Lowest balance after the correction: $117,027
(2026-07-31, before the rule starts).

**Known limitation (owner decision SIM-ECONOMICS):** the company remains loss-making; the funding keeps the books
consistent but is not a realistic business model. Recalibrating revenue against costs would change the plan from the
first day and therefore needs a regenerated history.

## Commands

```text
bench --site <site> portfolio-sim setup [--seed 20261119 --start 2025-08-01]
bench --site <site> portfolio-sim backfill [--until <iso>] [--max-events N]
bench --site <site> portfolio-sim status | integrity [--only a,b] | replay-check
bench --site <site> portfolio-sim live on|off | pause | resume
bench --site <site> portfolio-sim amend [--dry-run]   # events an additive rule placed on already-processed days
bench --site <site> portfolio-sim visitor-setup | public-settings
```

The scheduler runs `portfolio_sim.services.worker.tick` every minute. It does nothing unless the simulation is live
and not paused, executes at most 120 events per tick and never waits for the engine lock.

## Verification status

| Evidence | Status |
|---|---|
| `python -m unittest discover -s apps/erp/tests` (35 tests: RNG, calendar, catalogue, scenario, planner determinism, resume, references, chronology, quantities, stock replay, volumes, payments, supplier side, routines; compile and engine-isolation checks; static reference checks with self-tests) | **executed, 35/35 pass** |
| `python scripts/verification/check_erp_upstream.py` (pinned versions, 13 function signatures, controller methods, every DocType field, child field and Select value the services use, SQL columns, Standard chart accounts, fixtures, app DocTypes, hooks) | **executed, 675 checks, 0 problems** |
| `portfolio_sim/tests/test_lifecycle.py` (ERPNext `IntegrationTestCase`: setup, opening, document chains, pricing and discount, returns, payments, reconciliation, replay, no duplicates, crash recovery; document counts equal to the plan) | **executed on Linux: 7/7** on real Frappe/ERPNext v16.60.0 (GitHub Actions run 44425817273; 3,068 events, 36 integrity checks at 0, replay exact). Six application defects were found and fixed on the way (TEST_RESULTS "M5 — ERPNext integration on Linux") |
| Native Windows on the host | **running privately**; see TEST_RESULTS "M5 — Native Windows ERPNext (private)" |
| ERP browser E2E | `apps/erp/e2e` (Playwright): **7/7** against the private entry point |
