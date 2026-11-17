# Master Specification

Condensed, ID-tagged restatement of the owner's engineering directive. Requirement IDs are referenced from commits, tests, and `docs/TEST_RESULTS.md`. When this file and the original directive disagree, the directive wins and this file must be corrected.

## 1. Objective

Three independent, operational business applications (CRM, ERP, POS) built on designated open-source foundations, each with its own database, its own synthetic-data engine, live simulated activity, working auth/permissions, reports, and HTTPS deployment on the owner's existing Windows VPS at $0 additional cost. Plus a client-facing portal.

## 2. Foundations (fixed; change only with documented evidence + owner approval)

| ID | App | Foundation | Infra reference |
|---|---|---|---|
| F-CRM | CRM | marmelab/atomic-crm | Supabase (Postgres) |
| F-ERP | ERP | frappe/erpnext | frappe/frappe_docker |
| F-POS | POS | Blair2004/NexoPOS | Laravel + MySQL/MariaDB |

## 3. Cross-cutting requirements

| ID | Requirement |
|---|---|
| X-DB-1 | Each app keeps its own native schema, migrations, seeds, simulation rules, schedules, audit records, backup/restore, fixtures. No shared business schema. |
| X-DB-2 | Data is written through application services/ORM/API, never by raw inserts that bypass validation. |
| X-GEN-1 | ~500 curated semantic source values per app (names, products, industries, …) combined via rules/distributions/state machines into thousands of records. |
| X-GEN-2 | No placeholder-looking data ("Demo Customer 1"). Fictional identities, reserved email domains, fictional phone ranges, no real IDs or card numbers. |
| X-GEN-3 | Reproducible seeds; deterministic replay; scenario reset. |
| X-GEN-4 | 12–24 months history: growth, seasonality, weekday/business-hour variation, non-uniform distributions, valid exceptions, no impossible chronology. |
| X-GEN-5 | Referential integrity and relationship validation for all generated data. |
| X-LIVE-1 | Server-side live generator: persists events, respects business rules, pause/resume, adjustable speed, idempotent (no duplicates), restart recovery, bounded resources, auditable event log. |
| X-LIVE-2 | Never call real payment gateways, tax systems, or messaging services. |
| X-SEC-1 | No secrets in git; `.env.example` only; pre-push secret inspection. |
| X-SEC-2 | AuthN/Z, secure cookies, CSRF, validation, CORS, rate limiting, security headers, audit logging, dependency scanning. |
| X-SEC-3 | Databases private; only app endpoints public; owner's remote access preserved. |
| X-ACC-1 | Visitors get limited showcase accounts (no anonymous admin); visitors can't destroy shared data or see each other's changes; safe reset. |
| X-NET-1 | sslip.io hostnames only (`portfolio|crm|erp|pos.<IP>.sslip.io`), per-host HTTPS certs, auto-renew, HTTP→HTTPS, WebSocket/SSE support. |
| X-RES-1 | Measure resources before launching stacks; throttle simulators; log retention; restart policies; staged activation if resources insufficient. |
| X-DOC-1 | Synthetic nature and upstream authorship disclosed in docs, portal, and an in-app info section. |
| X-LIC-1 | Upstream licenses preserved; GPL derivatives stay GPL; MIT only for original separable work. |

## 4. CRM (F-CRM) — B2B technology services company

| ID | Requirement |
|---|---|
| CRM-F | Organizations, contacts, leads, opportunities, pipelines, tasks, meetings, notes, activity history, forecasting, team performance, dashboards, RBAC, search/filter, editable records. |
| CRM-G | Generator: companies, contacts, sales reps, account assignment, lead sources, opportunities, service interests, contract values, stages, follow-ups, won/lost, forecasts, renewals, relationship history. Non-uniform conversion rates; coherent chronology/ownership/value/state. |
| CRM-W | E2E workflow: new lead → qualification → opportunity → activities → proposal → negotiation → closed outcome → reporting update; automated test proves persistence + UI reflection at each stage. |

## 5. ERP (F-ERP) — multi-warehouse wholesale electronics distributor

| ID | Requirement |
|---|---|
| ERP-F | Purchasing, suppliers, sales orders, inventory, warehouses, stock transfers, invoicing, AR, AP, GL, payments, financial reports, reorder planning, returns, tax config, analytics. Standard document lifecycles. |
| ERP-G | Generator: customers, suppliers, items, warehouses, PO, PR, SO, DN, SI, PI, payment entries, stock ledger, GL entries, adjustments, returns, reconciliations. Balances reconcile; stock matches history; no orphans. |
| ERP-W | E2E workflow: reorder → PO → receipt → stock update → SO → delivery → invoice → payment → financial reporting. |
| ERP-R | Evaluate thava/erpnext_demo_gen and fafadiatech/demostackkit as references only (after quality/license review). |

## 6. POS (F-POS) — specialty retail store

| ID | Requirement |
|---|---|
| POS-F | Checkout, catalog, categories, SKUs, barcodes, inventory, customers, price adjustments, discounts, promotions, cashier ops, sales history, returns/refunds, payment simulation, receipts, registers, daily sales and stock reports, employee permissions. |
| POS-G | Generator: products/variants, SKUs, categories, stock, prices/costs (category-specific ranges), suppliers, customer histories, receipts, line items, promotions, refunds (referencing real past sales), shifts, payments, adjustments. Frequency varies by hour/weekday/promo/popularity. Sales affect stock and reports. |
| POS-W | E2E workflow: checkout → simulated payment authorization → receipt → stock decrement → customer history → daily sales report. |

## 7. Portal

| ID | Requirement |
|---|---|
| PRT-F | Premium responsive SaaS-style site: intro, CRM/ERP/POS showcases, tech overview, architecture highlights, access links, contact, open-source attribution. Accessible, fast, proper loading/error states. Never claims authorship of upstream products or paid delivery. |

## 8. Quality gates

Functional tests against persisted DBs; DB integrity tests (FKs, lifecycle transitions, idempotency, inventory, accounting, reset/replay); frontend tests (Playwright where appropriate); operational tests (startup, restart, worker recovery, persistence, HTTPS, public access, backups/restore, health endpoints, resource use). Untested = unverified.

## 9. Priorities

Correctness > security > data integrity > maintainability > reliability > UX > visual quality > performance > deployment simplicity > resource efficiency.
