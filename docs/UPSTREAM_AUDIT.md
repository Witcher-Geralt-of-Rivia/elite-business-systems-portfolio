# Upstream Audit (M1)

Audited 2026-11-17 from shallow clones in the git-ignored `upstream/` directory, plus GitHub API queries. **[V]** = verified in source/API, **[I]** = inference, to be confirmed during implementation.

## Pinned revisions

| App | Pin | Released | Notes |
|---|---|---|---|
| Atomic CRM | `main` @ `22f38f0f5918187a9c559e75dcc4cd4a329f9af2` | 2026-11-17 | `package.json` version is a placeholder `0.1.0`; CHANGELOG head is **v1.6.0** (2026-09-22). Re-pin to the v1.6.0 tag commit at M4 start if a tag exists. |
| ERPNext | **v16.60.0** (branch `version-16`) | 2026-11-17 | `develop` is v17-dev (`frappe>=17.0.0-dev`) — not used. |
| Frappe | **v16.60.0** | 2026-11-17 | ERPNext v16 requires `frappe>=16.60.0,<17`. |
| frappe_docker | `main` @ `0ad1a1152f93b1285104bcd0a8059e036dc5bd3d` | 2026-11-13 | Reference for process topology only (no Docker on host). |
| NexoPOS | **v6.3.0** | 2026-10-22 | `config/nexopos.php:12`. |

## Atomic CRM

- **Stack [V]:** Vite + React SPA on `ra-core` 5.15 / shadcn-admin-kit / Tailwind 4. Talks to Supabase directly (`supabase-js`): PostgREST, `rpc("global_search")`, `functions.invoke`, Storage (`src/components/atomic-crm/providers/supabase/dataProvider.ts`). Alternative in-browser FakeRest provider exists for the demo build only.
- **Supabase usage [V]:** RLS on all 11 tables (`supabase/schemas/05_policies.sql`); views `activity_log`, `companies_summary`, `contacts_summary`; ~20 plpgsql functions + 16 triggers; FTS. Extensions `citext`, `unaccent`, `pgcrypto`, plus **`http`** (sync Gravatar/favicon lookup in triggers) and **`pg_net`** (attachment cleanup). Auth = GoTrue email/password, invites, recovery, optional SSO, OAuth 2.1 server for MCP, ES256 signing keys. Storage bucket `attachments`. Six Deno edge functions (`users`, `update_password`, `merge_contacts`, `delete_note_attachments`, `postmark`, `mcp`). Realtime enabled but unused.
- **Schema [V]:** `companies`, `contacts`, `contact_notes`, `deals`, `deal_notes`, `tasks`, `tags`, `sales` (team members → `auth.users`, `administrator` flag), `configuration`, `user_invitations`, `favicons_excluded_domains`.
- **Gaps vs CRM-F:** no Lead entity (contact status only), single pipeline, meetings only as a task type, forecasting = one stage-weighted chart, **no team-performance reporting**, one fixed dashboard. These need new migrations + UI.
- **Permissions [V]:** two roles (admin/user). RLS is `using (true)` for all authenticated users — **no per-owner isolation**. Matters for X-ACC-1 (visitor isolation).
- **Customization [V]:** `<CRM>` props (`src/components/atomic-crm/root/CRM.tsx`): title, logos, themes, currency, sectors, deal stages/pipeline statuses/categories, note statuses, task types; swappable providers, dashboard, layout. Runtime config via `configuration` table.
- **Tests [V]:** Vitest (4 projects, ~57 files), Playwright e2e (7 specs) against local Supabase. Existing generator `providers/fakerest/dataGenerator/` (faker, browser-side) — reference only.
- **Windows without Docker:** feasible with effort. Windows binaries exist only for Postgres and PostgREST. GoTrue (Go, build from source or Linux binary under WSL1), Storage API (Node), edge functions (Deno has Windows builds), gateway (Caddy/Node). `http`/`pg_net` extensions have no official Windows builds → triggers must be stubbed/adapted.

## ERPNext / Frappe

- **License [V]:** ERPNext GPL-3.0 (`license.txt`); Frappe MIT; frappe_docker MIT. ERPNext ships `TRADEMARK_POLICY.md` — portfolio must not present itself as an official ERPNext product.
- **Runtime (v16) [V]:** Python **>=3.14,<3.15**; Node **>=24**; MariaDB **10.6–11.8** (frappe `setup_db.py::check_compatible_versions`); 2× Redis (cache, queue); wkhtmltopdf 0.12.6.1-3 or Chromium for PDFs. Process topology from frappe_docker: gunicorn, socketio (node), 2 RQ workers, scheduler, plus MariaDB + 2 Redis.
- **Resources [I]:** ~1.5–2.5 GB RAM steady state for a small site; `bench build` peaks 1–2 GB; ~4–6 GB disk.
- **Windows [V/I]:** not supported natively (gunicorn/RQ rely on `fork`). Bench supports linux/macos only. No published evidence for or against WSL1. Known WSL1 caveats: no systemd, slow filesystem metadata, MariaDB AIO (`innodb_use_native_aio=0`), Chromium PDF likely broken. Mitigation: MariaDB and a Redis-compatible server native on Windows; only Python/Node processes in WSL1. **Risk MEDIUM-HIGH; requires a time-boxed proof of concept.**
- **Extension [V]:** custom Frappe app — `hooks.py` `after_install`, `doc_events`, `scheduler_events` (incl. cron), `fixtures`; `@frappe.whitelist()` APIs; `frappe.enqueue(queue="long")`. Backdating via `set_posting_time=1` + `posting_date`, generated in chronological order.
- **Mappers on version-16 [V]:** `purchase_order.make_purchase_receipt` (L885), `.make_purchase_invoice` (L950); `sales_order.make_delivery_note` (L1419), `.make_sales_invoice` (L1603); `delivery_note.make_sales_invoice` (L1014), `.make_sales_return` (L1365); `purchase_receipt.make_purchase_invoice` (L1620), `.make_purchase_return` (L1784); `payment_entry.get_payment_entry` (L3113). (On `develop` these moved to `mapper.py` files.)
- **Built-in demo [V]:** removed in v16 (commit fc4fcda5); only a handful of master records remain. Custom generator required.
- **ERP-R evaluation [V]:** `thava/erpnext_demo_gen` — GPL-3.0, v16-targeted Frappe app with YAML packs (incl. a distributor pack), planner, writers calling real mappers, verify/snapshot. Created 2026-11-10, single author, 4 stars → **primary design reference; adapt patterns, do not depend on it.** `fafadiatech/demostackkit` — MIT, Docker-only, manufacturing-focused → **ignore**.
- **Tests [V]:** `ERPNextTestSuite(unittest.TestCase)` (`erpnext/tests/utils.py`), frappe `IntegrationTestCase`; `bench --site X run-tests --app <app>`.

## NexoPOS

- **License [V]:** `LICENSE` = GPL-3.0 and GitHub reports GPL-3.0; **`composer.json` says "MIT"** — upstream self-contradiction. We treat it as GPL-3.0 (stricter, matches the LICENSE file).
- **Stack [V]:** Laravel 12, PHP ^8.2 (`ext-curl, gd, mbstring, intl, zip`; no `pcntl`/`posix`), Vite 7 + Vue 3.5 + Tailwind 4, Node 24. DB: MySQL/MariaDB/SQLite (installer, `resources/ts/pages/setup/database.vue:135-145`); README recommends MariaDB 10.11 / MySQL 8.4. Queue defaults to `sync`, broadcasting to `log` (Reverb optional). Scheduler jobs in `routes/console.php`.
- **Windows [V]:** vendor ships a Windows edition (README); symlinks handled via `mklink`. Only shell-outs are in `UpdateCommand` (not used). **Feasible natively**: Task Scheduler for `schedule:run`, queue `sync` or a service-wrapped `queue:work`.
- **Simulator APIs [V]:** `OrdersService::create` (`app/Services/OrdersService.php:88`, transactional); `makeOrderSinglePayment` (:863); `refundOrder` (:1849); `CashRegistersService::openRegister/closeRegister/cashIng/cashOut`; `ProcurementService::create` (:108); stock via `ProductService::stockAdjustment` (driven by order events). Templates: `TestService::prepareOrder` (:71), `prepareProcurement` (:193). Many paths use `Auth::id()` → simulator must authenticate as a cashier.
- **Backdating [V]:** `created_at` accepted on orders/procurements; core's `ns:simulate` shifts time with `ns()->date->define()`. Dashboard/day/month aggregates are precomputed (`ReportService::computeDayReport`, `ns:report --compute`), so backfill must run with a controlled clock (`Carbon::setTestNow` + `ns()->date->define`) and recompute reports afterwards. **Upstream timestamp bug:** `OrdersService:1662` formats `'Y-m-d h:m:s'` (12-h hour, month as minutes) → always pass explicit `Y-m-d H:i:s`.
- **Module system [V]:** `modules/<Namespace>/` with `config.xml`, `<Namespace>Module.php`, Providers, Migrations, Routes, `Console/Commands` (auto-discovered), `Console/Kernel::schedule()`. Scaffold: `php artisan make:module`.
- **Install/roles/tests [V]:** unattended `php artisan ns:setup --store_name= --admin_username= --admin_email= --admin_password=`; roles admin, store administrator, cashier, customer, user, with granular permissions; PHPUnit 11 (~100 feature/unit tests incl. orders, refunds, registers, reports) + Playwright. Built-in `ns:reset --mode=wipe_plus_grocery --with-sales` demo (grocery) — not our domain; reference only.
