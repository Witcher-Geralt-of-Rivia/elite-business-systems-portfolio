# Acceptance Matrix — Release 1.0 (CRM + POS + Portal)

Each significant completion claim is mapped to verifiable evidence. Requirement IDs come from
[MASTER_SPECIFICATION.md](MASTER_SPECIFICATION.md). "TR" links point to sections of [TEST_RESULTS.md](TEST_RESULTS.md);
commits are on `main` of the public repository; host-side logs live under `C:\srv\portfolio\logs` (not published).

**Status legend:**
- **Met:** verified with recorded evidence.
- **Partial:** delivered with a stated gap (detailed in [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)).
- **Not in release:** outside Release 1.0.

Release-time re-verification (2026-11-18, about 13:10 local):
- **Public URLs:** CRM `/` and `/api/health` 200; POS `/sign-in` and `/harborpine/health` 200; portal `/`,
  `/status/crm` and `/status/pos` 200; co-hosted application 302 (its sign-in).
- **Integrity:** CRM 22/22, POS 43/43.
- **Tests:** CRM backend 42/42; portal browser check on desktop and phone, 0 errors.
- **Operations:** monitor runs all OK; every scheduled task's last result 0.

## 1. Release-level claims

| # | Claim | Status | Evidence |
|---|---|---|---|
| R1 | CRM publicly deployed over HTTPS with a trusted certificate | Met | TR [CRM M4 production](TEST_RESULTS.md#crm-m4--production-deployment-and-public-acceptance-2026-11-17); monitor `tls.crm` (89 days left at release); commits `60c629c`, `c92a55f` |
| R2 | POS publicly deployed over HTTPS (owner-approved) | Met | TR [POS public activation](TEST_RESULTS.md#pos-m6--public-activation-2026-11-18-d-017) (TLS 1.3, HSTS, secure cookie, 308 redirect); D-017; commit `d359c92` |
| R3 | Portal deployed, showing correct statuses and working links | Met | TR [M7](TEST_RESULTS.md#m7--portfolio-portal-deployment-2026-11-18) and the M9 re-check (desktop 1366 px / phone 390 px, 0 errors, links to the CRM/POS hosts, ERP "in preparation"); commits `bcce061`, M9 commit |
| R4 | Each app has its own database, engine and worker; nothing shared but the TLS front door | Met | [ARCHITECTURE.md](ARCHITECTURE.md); separate services `portfolio-crm-postgres` / `portfolio-pos-mariadb`; D-010, D-015 |
| R5 | Visitors explore both apps read-only without credentials | Met | CRM showcase 3/3 in public E2E (TR CRM M4 production); POS visitor 4/4 with 0 visitor-authored records (TR POS public activation, M8 §6); D-014 |
| R6 | Both live simulations operate continuously without duplicates | Met | CRM: live lead observed (TR M8 §11), restart keeps hash (TR CRM M4 production). POS: pause/restart/kill/concurrency suite (TR POS M6 local acceptance), 0 duplicate keys after activation and the dependency update (TR M8 §9) |
| R7 | Data integrity holds on production | Met | CRM `simulate integrity` 22/22; POS `hp:integrity` 43/43, both re-run at release (TR M8 §12 and this page) |
| R8 | Nightly backups with restore verification | Met | TR CRM PoC backup row, TR POS M6 (SYSTEM run, counts + text checksums), activation backup (TR POS public activation); monitor `backup.crm` / `backup.pos` |
| R9 | Monitoring with alerting on state change | Met | TR M8 §10 (10 checks; events 1001/1000 tested); commit `db5fe48` |
| R10 | No known vulnerable dependencies at release | Met | TR M8 §8–9 (`npm audit` 0/0/0; `composer audit` clean after update); commit `db5fe48` |
| R11 | Co-hosted owner application unaffected | Met | host Caddyfile SHA-256 unchanged across all reloads; Caddy never restarted (process start 2026-11-09); co-hosted site reachable after every change (TR M8 §12) |
| R12 | Upstream licensing and attribution preserved | Met | [UPSTREAM_LICENSES.md](UPSTREAM_LICENSES.md); MIT `apps/crm/frontend/LICENSE.md`; GPL-3.0 `apps/pos/modules/HarborPine/LICENSE`; portal "Credits and honesty"; TR M8 §8 |
| R13 | ERP delivered | **Not in release** | M5 on hold (REBOOT); see [FINAL_DELIVERY.md §6](FINAL_DELIVERY.md#6-outstanding-erp-milestone-m5) |
| R14 | Host security remediated | **Not claimed** | R-014 open (SEC-ROTATE); [SECURITY_INVESTIGATION.md](SECURITY_INVESTIGATION.md) |

## 2. Cross-cutting requirements

| ID | Requirement (short) | Status | Evidence / note |
|---|---|---|---|
| X-DB-1 | Own schema, migrations, rules, audit, backup per app | Met | CRM migrations `apps/crm/backend/migrations`; POS module migrations; separate backup scripts and tasks |
| X-DB-2 | Writes through application services | Met | CRM engine writes via ResourceService, audited as `simulator` (TR CRM M4 frontend: "every write audited"); POS engine via NexoPOS services (POS_DATA_ENGINE.md). One-time maintenance commands (`hp:repair-refunds`, `hp:presentation`) are idempotent, documented module commands, rehearsed on clones |
| X-GEN-1 | ~500 curated source values | Met | CRM ~500 (test-enforced 450–600); POS `Data/catalog.json` 828 leaf values (including numeric parameters) |
| X-GEN-2 | No placeholder data; fictional identities, reserved domains | Met | `.example` / `mail.example` domains, 555-01xx phones; acceptance walkthrough fixes `34e0b1c`, `52f7cbc` |
| X-GEN-3 | Reproducible seeds, deterministic replay, reset | Partial | CRM: identical hash for the same seed (TR CRM M4 frontend). POS: replay over the full year 26,754/26,754 and identical replay after the dependency update (TR M8 §9). POS scenario reset is not exercised on production by design (history generated once) |
| X-GEN-4 | 12–24 months, seasonality, business hours, valid chronology | Met | CRM 13 months, weekend share 0; POS 12 months, 362 trading days, monthly curve (TR POS M6); chronology checks in both integrity suites |
| X-GEN-5 | Referential integrity | Met | FK and reference checks in CRM (22) and POS (43) integrity suites |
| X-LIVE-1 | Live generator: rules, pause/resume, speed, idempotent, restart recovery, bounded, auditable | Met (POS) / Partial (CRM) | POS: `hp:sim pause/resume`, ledger, recovery suite, memory recycle (TR POS M6). CRM: advisory lock, persisted queue, restart-safe hash (TR CRM M4 production), intensity setting; pausing needs a config change and service restart |
| X-LIVE-2 | No real gateways, tax or messaging services | Met | simulated card method; CRM has no email sending (one-time links shown in the UI); POS telemetry kept on the server (TR M8 §2) |
| X-SEC-1 | No secrets in git; pre-push inspection | Met | `.gitignore`, `.env.example` only; staged-diff scan for IPs and secrets before every push (recorded in commit workflow); secrets on the host only |
| X-SEC-2 | AuthN/Z, cookies, CSRF, validation, rate limits, headers, audit, dependency scanning | Met (CRM) / Partial (POS) | CRM: TR CRM backend PoC + M4. POS: upstream auth/CSRF/throttle, secure HttpOnly cookie, HSTS etc.; CSP without `script-src` (inline scripts upstream); rate limit returns 500 instead of 429 (KNOWN_LIMITATIONS) |
| X-SEC-3 | Databases private; only app endpoints public | Met | all databases/workers on loopback; POS loopback listener serves health only |
| X-ACC-1 | Limited showcase accounts; no shared-data damage | Met | read-only enforcement at HTTP and service layers (CRM) and ShowcaseGuard (POS); E2E asserts 0 visitor writes |
| X-NET-1 | sslip.io hosts, per-host HTTPS, renewal, redirect, SSE | Met | three certificates (monitor `tls.*`), 308 redirects, SSE delivery (TR M8 §11) |
| X-RES-1 | Measured resources, throttles, retention, restart policies | Met | TR M8 resources (under 1.5 % of one core in total); WinSW restart policy; backup 14-day and monitor 12-month retention; Caddy log rolling |
| X-DOC-1 | Synthetic data and upstream authorship disclosed (docs, portal, in-app) | Met | README honesty statement, portal credits, in-app banners ("Read-only demo · Harbor & Pine Market (fictional)") |
| X-LIC-1 | Licences preserved; GPL derivatives stay GPL | Met | R12 |

## 3. CRM requirements

| ID | Status | Evidence / note |
|---|---|---|
| CRM-F (records, pipeline, tasks, notes, activity, dashboards, RBAC, search, editable records) | Partial | Delivered and tested: TR CRM backend PoC (RBAC, record rules), M4 (search, team, merge, attachments, SSE), public E2E 10/10. Meetings appear as notes of type "Meeting"; no dedicated forecasting or team-performance reports beyond Atomic CRM's dashboard (KNOWN_LIMITATIONS) |
| CRM-G (generator scope, non-uniform conversion, coherent chronology) | Met | [CRM_DATA_ENGINE.md](CRM_DATA_ENGINE.md); win rate 31.0 %, seasonal leads; engine tests 7/7 inside the 42/42 backend run |
| CRM-W (lead → qualification → opportunity → … → closed → reporting) | Partial | The full lifecycle runs through the service layer in the engine and is checked by integrity, and a production lead was observed end to end (TR M8 §11). Browser E2E covers create/update/delete, search, merge and SSE, but not one test walking a single deal through every stage in the UI |

## 4. POS requirements

| ID | Status | Evidence / note |
|---|---|---|
| POS-F (checkout, catalogue, inventory, customers, discounts, promotions, cashier ops, returns, simulated payments, receipts, registers, reports, permissions) | Met | NexoPOS upstream features plus module; admin E2E 9/9 (TR M8 §6, §9); visitor role permissions (TR POS public activation) |
| POS-G (catalogue, stock, prices, suppliers, customer histories, promotions, refunds of real sales, shifts, payments) | Met | TR POS M6 dataset; integrity checks `refund_*`, `register_*`, `sold_before_stocked`; [POS_DATA_ENGINE.md](POS_DATA_ENGINE.md) |
| POS-W (checkout → simulated payment → receipt → stock decrement → customer history → daily report) | Met | admin E2E tests 3–6 on an isolated clone, 9/9 twice (TR M8 §6) and on the updated dependencies (TR M8 §9) |

## 5. Portal

| ID | Status | Evidence / note |
|---|---|---|
| PRT-F (responsive site, showcases, tech, architecture, links, attribution, honest claims) | Partial | TR M7 and the M9 re-check: desktop/phone, strict CSP, live statuses, credits. M9 corrected the hero, which claimed three running systems. No contact section (KNOWN_LIMITATIONS) |

## 6. ERP (not in Release 1.0)

| ID | Status | Note |
|---|---|---|
| ERP-F, ERP-G, ERP-W | Not in release | M5 on hold at release; runtime needs owner decision REBOOT. Post-release: app and engine implemented, ERPNext tests not yet executed ([ERP_DATA_ENGINE.md](ERP_DATA_ENGINE.md#verification-status)) |
| ERP-R (reference evaluation) | Met (research) | [UPSTREAM_AUDIT.md](UPSTREAM_AUDIT.md) evaluates `erpnext_demo_gen`; R-012 |

## 7. Milestones

| Milestone | Status | Evidence |
|---|---|---|
| M0 Repository | done | TR M0 |
| M1 Upstream audit | done | UPSTREAM_AUDIT.md, commit `3bcd31f` |
| M2 VPS compatibility | done | TR M2, D-008/D-009 |
| M3 Infrastructure | done | TR Consolidation, CRM PoC backup/health rows |
| M4 CRM | done | TR CRM sections, M8 §11 |
| M5 ERP | **on hold** | REBOOT decision pending |
| M6 POS | done (public, D-017) | TR POS M6 + public activation |
| M7 Portal | done | TR M7, M9 re-check |
| M8 Security/integration/performance | technically complete for CRM + POS + portal; R-014 owner-side | TR M8 |
| M9 Final delivery (Release 1.0) | done for CRM + POS + portal | this package; TR M9 |
