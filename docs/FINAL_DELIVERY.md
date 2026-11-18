# Final Delivery — Elite Business Systems Portfolio, Release 1.0 (CRM + POS + Portal)

Release date: 2026-11-18 · Repository: https://github.com/Witcher-Geralt-of-Rivia/elite-business-systems-portfolio

> **Scope of this release.** Release 1.0 delivers the **CRM**, the **POS** and the **portfolio portal**, deployed
> and verified. The **ERP (ERPNext) is not part of this release**. It remains an open implementation milestone
> (M5, on hold) and is described in [§6](#6-outstanding-erp-milestone-m5). The project as a whole
> (CRM + ERP + POS) is therefore **not complete**.

## 1. What was delivered

Two **customised open-source business applications** and a portal, running on the owner's Windows VPS behind
HTTPS. Each application has its own database, a year of fictional synthetic business history and a live
simulation that keeps generating activity.

| Component | Public address | Built on (upstream author, licence) | Fictional business |
|---|---|---|---|
| CRM | `https://crm.<VPS_IP>.sslip.io` | [Atomic CRM](https://github.com/marmelab/atomic-crm) (Marmelab, MIT) | *Meridian Advisory*, B2B operations-analytics software and services |
| POS | `https://pos.<VPS_IP>.sslip.io` | [NexoPOS](https://github.com/Blair2004/NexoPOS) v6.3.0 (Blair Jersyer, GPL-3.0) | *Harbor & Pine Market*, coastal specialty food and home store |
| Portal | `https://portfolio.<VPS_IP>.sslip.io` | original work (MIT) | presents and links the applications, with live status |

**Authorship and honesty.** The CRM and POS products were created by their upstream authors. This project contributes:
- the customisations;
- the CRM's own API, which replaces upstream's Supabase backend;
- a NexoPOS module (store, simulation, visitor mode);
- both synthetic-data engines;
- the deployment, operations and test tooling;
- the portal.

All companies, people, products and transactions are **fictional**, and payments are simulated. These are showcase
environments, not work delivered to a client.

Visitors explore both applications **read-only without credentials** ("Explore the live demo" on each sign-in page).

## 2. Functionality

### CRM — Atomic CRM UI on a project-built API

| Area | Delivered |
|---|---|
| Records | companies, contacts, deals (pipeline: opportunity → proposal → negotiation → won/lost, with delays), notes, tasks, tags |
| Views | dashboard (deal revenue chart, hot contacts, upcoming tasks, latest activity), kanban pipeline, lists with search and filters |
| Team | first-user admin, invitations with one-time password links, roles (admin/sales rep), disable/enable, record-level permissions |
| Features | accent-insensitive global search, contact merge, private attachments, real-time updates over SSE, audit log |
| Backend | Fastify API (Node 24) on a dedicated PostgreSQL 16 cluster: session auth (scrypt, lockout, CSRF, rate limits), server-enforced RBAC. Supabase removed (D-009) |
| Visitors | credential-free showcase sessions, read-only at both the HTTP and service layers (D-014) |

### POS — NexoPOS with the *Harbor & Pine Market* module

| Area | Delivered |
|---|---|
| Upstream features | POS checkout screen, catalogue (categories, SKUs, barcodes, units), inventory and stock history, customers and accounts, registers (open/close, cash in/out), orders, refunds, procurements from suppliers, taxes, discounts/coupons, receipts, sales/stock/profit/payment reports and dashboards |
| Module (GPL-3.0, `apps/pos/modules/HarborPine`) | store set-up (88 products, 12 categories, 11 suppliers, 2 registers, 5 staff); a retail engine that runs the store through NexoPOS's own services; live worker; integrity, replay, repair and presentation commands; visitor mode; health endpoint |
| Payments | cash and a **simulated** card method (no gateway is ever called) |
| Visitors | read-only showcase role. The POS screen works as a **checkout preview**: a complete sale is shown and then refused with an explicit "not saved" message. Admin areas are refused |
| Upstream adjustments (no core patches) | race-free installed-state check, telemetry kept on the server, visitor background calls; see [POS_DATA_ENGINE.md](POS_DATA_ENGINE.md#upstream-behaviour-adjusted-by-the-module-no-core-patches) |

### Portal

Responsive static site with the application showcases, real screenshots, live status per application
(same-origin `/status/crm` and `/status/pos`), data and architecture explanations, and credits naming the
upstream authors and licences. Strict CSP: no external resources, no cookies.

## 3. Independent data engines

| | CRM engine | POS engine |
|---|---|---|
| Code | `apps/crm/backend/src/simulation/` (TypeScript) | `apps/pos/modules/HarborPine/Services/` (PHP) |
| Writes through | the API's ResourceService (validation, permissions, audit) | NexoPOS services (OrdersService, ProcurementService, CashRegistersService, …) |
| Curated source values | ~500 (`catalog.json`, test-enforced 450–600) | `Data/catalog.json` (products, suppliers, customers, staff, promotions) |
| History | 13 months, seed 20261117 | 12 months, seed 20261118 (2025-11-17 → 2026-11-17, generated once, never regenerated) |
| Model | Poisson leads (seasonality, growth, business hours), regional assignment, qualification, stage transitions by rep skill, follow-ups, expansions | hourly/weekday/seasonal footfall, basket model, promotions, cash/card mix, returns referencing real earlier sales, supplier deliveries, register sessions |
| Determinism | seeded RNG; persisted state and event queue; byte-identical replay (hash) | seeded RNG per day; idempotency ledger (one stable key per event); replay check ledger = plan |
| Live | in-process worker, 60 s tick, advisory lock, intensity 3 | Windows service `portfolio-pos-sim`, `GET_LOCK`, watermark, pause/resume, recycle with exit code 3 |
| Integrity | 22 checks | 43 checks |
| Docs | [CRM_DATA_ENGINE.md](CRM_DATA_ENGINE.md) | [POS_DATA_ENGINE.md](POS_DATA_ENGINE.md), [POS_NEXOPOS_INTERNALS.md](POS_NEXOPOS_INTERNALS.md) |

Dataset at release (2026-11-18):
- **CRM:** 500 companies, 1,268 contacts, 295 deals (81 won, 181 lost, $2,070,500 won), 1,338 tasks, 1,856 notes.
- **POS:** 24,348 orders, 67,098 lines, 280 returns, 586 procurements, 70,660 stock movements, 726 register
  sessions, 421 customers; paid sales $872,053.27, equal to the dashboard figure.

## 4. Architecture and technologies

```text
Internet ──HTTPS──► Caddy (host service; graceful reloads only; Let's Encrypt via sslip.io)
                     ├─ portfolio.<VPS_IP>.sslip.io → static portal (+ /status/* proxies)
                     ├─ crm.<VPS_IP>.sslip.io       → Atomic CRM build (static) + /api → Fastify API ─► PostgreSQL 16
                     │                                                     └ simulation worker (in-process)
                     └─ pos.<VPS_IP>.sslip.io       → php_fastcgi → 2 php-cgi workers (NexoPOS) ─► MariaDB 11.8
                                                       simulation worker (Windows service) ─────────┘
All databases and workers listen on loopback only.
```

| Layer | Technology |
|---|---|
| Host | Windows Server 2025 VM (3 vCPU, 12 GB RAM); no nested virtualisation, so everything runs natively (R-001) |
| Edge | Caddy 2 (shared host service) with per-site files imported from `C:\srv\portfolio\caddy` |
| CRM | React/react-admin (Atomic CRM snapshot `22f38f0f`), Vite build; Node 24, Fastify 5, pg; PostgreSQL 16 |
| POS | PHP 8.3 NTS (FastCGI), Laravel 12.73 (NexoPOS v6.3.0, dependencies security-updated), MariaDB 11.8 |
| Services | WinSW wrappers under least-privilege accounts (LocalService / NetworkService); Task Scheduler for backups and monitoring |
| Tests | Node test runner, Playwright (Chromium) for desktop and phone, PowerShell verification suites |

Full detail: [ARCHITECTURE.md](ARCHITECTURE.md) · deployment layout: [DEPLOYMENT.md](DEPLOYMENT.md) ·
decisions: [DECISIONS.md](DECISIONS.md).

## 5. Verified results (summary)

Every line links to evidence in [ACCEPTANCE_MATRIX.md](ACCEPTANCE_MATRIX.md) and [TEST_RESULTS.md](TEST_RESULTS.md).

| Area | Result |
|---|---|
| CRM browser tests on the public URL | 10/10 (login, CRUD, search, invitations, attachments, SSE, merge, visitor mode); cleanup leaves 0 test accounts |
| CRM backend suites | 42/42 (auth, permissions, team, search, merge, attachments, SSE, engine determinism), re-run at release |
| CRM integrity (production) | 22/22, re-run at release |
| CRM live activity | lead observed in production at its planned time, audited and pushed by SSE (59 ms) |
| POS integrity (production) | 43/43, re-run at release; replay of the full year 26,754/26,754 events |
| POS admin workflow (isolated clone) | 9/9: register, checkout by API and POS screen, receipt, history, reports, refund, close, telemetry |
| POS public visitor tests | 4/4 desktop and phone, 0 visitor-authored records |
| POS worker recovery | pause/resume, service restart, mid-day kill and concurrent engines: no loss, no duplicates |
| Backups | nightly with restore check into scratch databases (row counts; POS also text checksums) |
| Dependencies | `npm audit` clean (CRM backend/frontend); `composer audit` clean after the 2026-11-18 update |
| Monitoring | 10 checks every 15 minutes as SYSTEM, with event-log alerts on state change (tested) |
| Performance | hosted services use under 1.5 % of one core; CRM, portal and co-hosted app 55–70 ms median; POS about 0.34 s (PHP-CGI boot) |

## 6. Outstanding ERP milestone (M5)

**ERPNext is not implemented or deployed.** What exists and is preserved:
- **Pins:** ERPNext/Frappe **v16.60.0** (D-005).
- **Runtime research:**
  - Frappe v16 needs Python 3.14, Redis and fork-based workers, so it has no native Windows runtime (R-002).
  - With no nested virtualisation, WSL2 and Docker are impossible (R-001).
  - The chosen path is WSL1 with native MariaDB (D-007, R-011). It requires enabling the WSL feature and a
    **Windows reboot, which is not approved**.
- **Runbook:** [runbooks/ERP_WSL1_REBOOT.md](runbooks/ERP_WSL1_REBOOT.md), not executed.
- **Upstream audit:** [UPSTREAM_AUDIT.md](UPSTREAM_AUDIT.md) covers extension points (custom Frappe app, hooks,
  scheduler) and generator references (ERP-R).
- **Portal:** shows the ERP as "in preparation" with no link.

Release 1.0 makes no ERP claims. The ERP needs the owner's decision **REBOOT** before any runtime work.

## 7. Security status (separate from application engineering)

- **Incident R-014 remains open.** The host ran an information-stealer loader on 2026-10-07; see
  [SECURITY_INVESTIGATION.md](SECURITY_INVESTIGATION.md) (sanitised). The owner resumed work without a rebuild (D-013)
  and approved the public POS (D-017).
- **What the tests show:** application tests, dependency audits and monitoring describe the applications only.
  They **do not establish that the Windows host is remediated**.
- **Outstanding owner-controlled actions (SEC-ROTATE):**
  - rotate credentials from a trusted device;
  - remediate or rebuild the host;
  - fix the Defender hardening gaps (R-015).
- **Applications:** the repository contains no secrets, credentials, host inventory or raw incident evidence.
  Secrets live in an Administrators/SYSTEM-only folder on the host.

## 8. Documents in this package

| Document | Purpose |
|---|---|
| [ACCEPTANCE_MATRIX.md](ACCEPTANCE_MATRIX.md) | every significant claim mapped to tests, logs or commits |
| [OPERATIONS_HANDBOOK.md](OPERATIONS_HANDBOOK.md) | services, dependencies, daily operation, maintenance, monitoring |
| [RECOVERY_GUIDE.md](RECOVERY_GUIDE.md) | backups, restore, rollback commands, incident playbooks |
| [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) | what is not done, not guaranteed, or deliberately constrained |
| [TEST_RESULTS.md](TEST_RESULTS.md) | dated raw evidence of every test run |
| [PROGRESS.md](PROGRESS.md), [ROADMAP.md](ROADMAP.md), [`state/checkpoint.json`](../state/checkpoint.json) | history, milestones, machine-readable state |

## 9. Remaining owner decisions

| ID | Decision | Effect |
|---|---|---|
| SEC-ROTATE | credential rotation and host remediation/rebuild (R-014, R-015) | closes the open security incident; independent of the applications |
| REBOOT | enable WSL and reboot Windows for the ERP runtime | unblocks M5 (ERP); until then the ERP stays repository-only |
