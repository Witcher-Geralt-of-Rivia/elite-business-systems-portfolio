# Progress Log

Newest first. Every entry states what was **verified**, not just what was written.

## 2026-11-19 — M5: ERPNext on the VPS without WSL or reboot — QEMU-TCG measured, native Windows spiked

- **QEMU-TCG (owner directive):** QEMU 11.1.0 software emulation runs a Debian 13 guest on the VPS (fixes: SMM off,
  Task Scheduler launch). Real Frappe/ERPNext v16.60.0 + portfolio_sim installed in the guest. Linux platform
  checks pass. Throughput ~0.05 events/s (requirement 0.35): **not practical for permanent operation**. Production
  latency unaffected at below-normal priority (watchdog evidence). Integration run 1 was invalidated by the dev
  supervisor (Redis stopped after a worker exit); **run 2 on a fresh site with per-process systemd units: 7/7 in
  12.6 h, integrity 36/0, replay exact, state hash and GL identical to CI.** Guest shut down cleanly afterwards.
- **Native Windows spike (failure handling 9.6):** the same pinned sources on Windows-native Python 3.14 with ten
  runtime adaptations and no upstream edits: **7/7 integration tests, integrity 36/0, replay exact, state hash and
  GL identical to CI, 1.3–1.4 events/s**; web (waitress) and worker (no fork, timer timeouts) verified. Desk asset
  build on Windows not working yet.
- **Waiting for the owner:** ERP-RUNTIME (native Windows recommended) and REDIS-WINDOWS. Release 1.0 untouched.

## 2026-11-18 — M5: pre-reboot readiness prepared; waiting for the owner's console confirmation and window

- **New scripts:**
  - `preflight-reboot.ps1` (S0 gate): **0 failing** (33 pass), including fresh CRM and POS backups with restore
    checks.
  - `post-reboot-check.ps1` (S1 criterion): trial 25/25 in the current state.
  - `set-db-service-recovery.ps1`: prepared as a dry run, not applied.
- **Co-hosted identifiers:** read from a host-side config. Earlier service names and a URL path were removed from the
  repository text.
- **Runbook:** WSL1 only, with `wsl --import … --version 1` and never `wsl --install`, VirtualMachinePlatform,
  Hyper-V or WSL2. Platform smoke P1–P6 (system calls, Redis, workers, scheduler, process recovery, boot autostart)
  runs before any history. ERP MariaDB stays isolated, and ERPNext private.
- **Queued file operations at the next boot:** spooler cache cleanup, Chrome leftovers and an Edge log rotation;
  no system files.
- **Waiting for the owner:** out-of-band console confirmation, maintenance window, REBOOT approval, and optionally
  the database recovery actions. Nothing on Windows was changed.

## 2026-11-19 — M5: ERPNext integration tests pass on Linux (GitHub Actions); WSL1 still untested

- **Workflow:** `.github/workflows/erp-integration.yml`, manually triggered. A real Frappe bench and ERPNext v16.60.0
  (Python 3.14, Node 24, MariaDB 11.8, Redis) on a temporary Ubuntu 24.04 runner, with an isolated throwaway site.
  No production credentials and no VPS access.
- **Result:** run 44425817273 passed **7/7**.
  - 3,068 events over 64 business days, every submitted document count equal to the deterministic plan.
  - Purchasing, sales with partial deliveries, invoices, customer and supplier payments, advances, returns, credit
    and debit notes, and reconciliation.
  - **36 integrity checks at 0**; replay 3,068 = 3,068.
  - Exactly-once: a re-run adds nothing, and an injected crash recovers. About 3.9 events/s.
- **Found and fixed on real ERPNext** (11 runs, every failure recorded):
  - **App defects:** packaging README; Gender fixtures; Stock Reconciliation over 100 rows queued instead of
    submitted; mapper due dates computed from today; **every order priced at 0** (ERPNext fills server-side item
    fields only when `None`); credit-note reconciliation journals dated today.
  - **Check corrections:** the Bin check; advances excluded from payment-before-invoice; integrity/replay refuse an
    empty site.
  - **CI guard:** Frappe v16's `--skip-test-records` silently runs nothing, which made one run a false pass.
- **Limits:** Linux runtime validation only. WSL1 compatibility, the host deployment and browser tests remain open.
- **Reboot readiness:** read-only inspection recorded in the PoC runbook. Technically ready, conditional on the owner
  confirming the provider console, choosing a window and approving REBOOT. The database services have no
  restart-on-failure actions (recommendation, not changed). The reboot is **not** authorised.

## 2026-11-18 — M5 started: ERPNext custom app and distribution engine implemented (no runtime yet)

- **App:** `apps/erp/portfolio_sim`, a custom Frappe app (GPL-3.0) for ERPNext/Frappe v16.60.0. It contains:
  - hooks (live worker tick), bench commands, two DocTypes (event ledger, settings);
  - setup through ERPNext's own programmatic `setup_complete`, plus master data;
  - an executor using ERPNext's mappers with insert and submit;
  - an exactly-once simulator, 32 integrity checks and a replay check.
- **Scenario:** *Sable Ridge Electronics Supply Co.*, a fictional Ohio wholesale electronics distributor,
  independent of the CRM and POS. 497 curated values, 96 items, 12 suppliers, 150 customers, 24 staff, 4
  warehouses. 15½ months of planned history (26,461 events) covering purchasing, receiving, billing, payments,
  selling with backorders, invoicing, returns and credit/debit notes, reconciliation, transfers, cycle counts and
  expenses.
- **Verified without ERPNext:** engine and static tests 35/35, and 675 checks against the pinned sources with 0
  problems. The first checker run found a real v16 difference (Item Group has no description field), now fixed.
- **Not yet executed:** the 7 ERPNext integration tests, integrity and replay on a site, and browser tests.
  ERPNext is **not** claimed operational.
- **Runtime plan:** [runbooks/ERP_WSL1_POC.md](runbooks/ERP_WSL1_POC.md). Staged gates S0–S8 and failure
  criteria F1–F7 cover throughput, resources, latency impact and stability, with alternatives A1–A4. The ERP gets
  its own MariaDB instance, so the POS database server stays untouched. The reboot runbook now lists the
  Release 1.0 services it affects.
- **Unchanged:** Release 1.0 not modified or redeployed; no WSL, no reboot; R-014 remains an open owner action.

## 2026-11-18 — M9: Release 1.0 (CRM + POS + Portal) delivered; ERP remains outstanding

- **Release scope (D-018):** "Elite Business Systems Portfolio — CRM + POS + Portal, Release 1.0". The ERP is an
  outstanding milestone (M5 on hold); the project as a whole is not finished.
- **Final acceptance** ([evidence](TEST_RESULTS.md#m9--release-10-final-acceptance-2026-11-18-crm--pos--portal)):
  - all public URLs answer;
  - CRM integrity 22/22, POS 43/43, CRM backend 42/42;
  - backups current, monitor all OK;
  - portal checked on desktop and phone;
  - the co-hosted application is unaffected.
- **Delivery package:** FINAL_DELIVERY, ACCEPTANCE_MATRIX (every claim mapped to evidence), OPERATIONS_HANDBOOK,
  RECOVERY_GUIDE, KNOWN_LIMITATIONS. README rewritten for the release (customised open-source showcases,
  synthetic data, upstream attribution, ERP status, security note).
- **Corrections found by the review:**
  - the portal hero claimed three running systems;
  - ARCHITECTURE claimed a NexoPOS scheduler task that does not exist (now limitation L21);
  - licence boundary paths and three risk statuses were stale.
- **Unchanged:** R-014 open (owner: SEC-ROTATE); the ERP waits for REBOOT. Next: non-disruptive ERP preparation
  in the repository only.

## 2026-11-18 — M8 technically complete; CRM live-lead observation closed

- **CRM observation (pending since M4):** the day's single scheduled lead arrived at its planned business time
  (20:48:48 UTC) with contacts, an intro note and a task. All 7 records were audited as `simulator`, and the SSE
  insert reached the subscriber 59 ms after commit. There was no missing activity: before it arrived, the engine
  state showed exactly one lead queued for the day. Nothing was reset.
- **Integration regression:** CRM public E2E 10/10 (cleanup clean), CRM integrity 22/22, POS integrity 43/43,
  public POS visitor 4/4. Portal status routes OK, Práctica reachable, host Caddyfile unchanged, Caddy never
  restarted.
- **M8 status:** technically complete for CRM, POS and portal. The host incident R-014 stays open as an owner
  action (SEC-ROTATE); public deployment does not establish that the VPS is remediated. Next: M9 final delivery
  for the deployed applications; ERP stays on hold.

## 2026-11-18 — M8: dependency security update, licence review, monitoring

- **PHP dependencies:** NexoPOS v6.3.0's lock had published advisories in 11 packages. The critical Laravel
  TokenGuard bypass is not reachable here, but request-path issues applied to the public site.
  - Updated inside upstream's constraints (Laravel 12.73.0); `composer audit` is clean.
  - Verified on staging: admin 9/9, visitor 4/4, recovery suite with an identical deterministic replay,
    integrity 43/43.
  - Promoted with about one minute of POS downtime and automatic rollback ready; public visitor suite 4/4
    afterwards. Script: `update-pos-dependencies.ps1`.
- **Licences:** no conflicts in the CRM runtime trees (permissive plus OFL/MPL components used as intended).
  `npm audit` is clean for both CRM trees and the test tooling.
- **Monitoring:** `Portfolio - health monitor` runs every 15 minutes as SYSTEM, covering public health, POS
  worker lag, TLS lifetime, services, backups and disk (the R-004 alarm). It logs JSON lines and writes event-log
  entries on state changes; the failure and recovery events were tested.
- **Docs:** DEPLOYMENT now has the backup schedule, recovery runbook, monitoring and dependency-update sections.
  R-014 status wording now matches D-013/D-017; the host is still not declared clean.

## 2026-11-18 — M8 in progress: public POS hardened, upstream race fixed, performance re-measured

- **Visitor-facing defect found and fixed:** NexoPOS deletes its cached "installed" flag after every response and
  reads it non-atomically. Under concurrent requests visitors were sometimes sent to the installer, so the POS
  catalogue showed empty, and app boot occasionally failed with a 500.
  - Fixed through the module: listener replaced, plus a DB-confirmed middleware fallback.
  - Before: 1 in 348 parallel calls. After: 0 in 623, with no fallback hits or boot errors.
  ([evidence](TEST_RESULTS.md#m8--integration-performance-and-operational-validation-2026-11-18-public-pos))
- **Privacy:** upstream telemetry, which carries the host name with the server address, is answered locally.
  Marketplace and OAuth pages are refused for visitors.
- **Polish:**
  - the translation file is now served (Caddy read access on the `lang` junction target);
  - visitor onboarding tours suppressed;
  - POS CSP for the non-script directives.
- **Tests:**
  - shared POS-screen helpers absorb two upstream UI timing branches;
  - admin E2E gained a telemetry test;
  - visitor E2E fails on any failed response.
  Results: admin 9/9 twice, public visitor 4/4 twice.
- **Performance** with everything public: hosted services under 1.5 % of one core. POS about 0.34 s median (PHP
  boot), CRM, portal and Práctica 55–70 ms. Host RAM growth is interactive tooling, not hosted services.

## 2026-11-18 — M6 publicly deployed and verified (D-017)

- **Owner approved public access (POS-PUBLIC).** The POS is live at `https://pos.<VPS_IP>.sslip.io` with read-only
  visitor entry ([evidence](TEST_RESULTS.md#pos-m6--public-activation-2026-11-18-d-017)).
- **Activation script:**
  - The first run stopped safely in preflight on a false "8 failing checks": an empty JSON array was miscounted.
    Nothing had changed. Fixed and re-run.
  - The re-run passed 43/43 integrity checks and made a fresh backup, restored with matching counts and text
    checksums.
  - It validated the Caddyfile, reloaded Caddy gracefully, passed the HTTPS smoke checks and the public visitor
    suite (4/4, 0 visitor records), and switched the portal POS card to operational automatically.
- **Independent checks:**
  - TLS 1.3 with a trusted certificate; HTTP→HTTPS redirect; HSTS.
  - Secure, HttpOnly session cookie.
  - Wrong passwords refused; dashboard and API closed without a session; registration disabled; no exposed
    files.
  - Worker: no duplicates; a sale after activation was recorded on time.
  - CRM, Práctica and portal reachable. The host Caddyfile and Caddy process are unchanged (reload only).
- **Screenshot review:** the phone dashboard capture now waits for the card figures. The checkout message is
  asserted above the banner. The upstream footer credit is lifted clear of the banner on phones. Public suite
  re-run 4/4.
- **CRM live-lead observation:** still running (window ends 13:05 local). So far the live connection is up with
  routine events and no lead yet. The engine is current (clock = real time) and has exactly one lead
  scheduled today, at 20:48 UTC, inside the window. Nothing is missing; the dataset was not touched.
- **Unchanged:** the security incident stays open (public release ≠ host remediation). ERP stays on hold
  with no reboot.

## 2026-11-18 — M7: portfolio portal deployed

- Portal live on the portfolio host: three applications with real screenshots, live status (same-origin
  `/status/crm`), data and architecture sections, credits. CRM linked; POS shown as "being finalised" (no link,
  no status route) until the owner approves its public activation; ERP "in preparation".
- `deploy-portal.ps1`: config from host state, atomic swap with rollback, graceful Caddy reload only, smoke tests.
  Host Caddyfile untouched; CRM, Práctica and POS loopback verified after the reload.
- Browser check desktop + phone: 0 errors, no horizontal scroll, strict CSP.
- POS activation now also switches the portal (and back on rollback); the POS public site keeps a loopback
  health listener for the portal status route.

## 2026-11-18 — M6 local acceptance: full POS dataset verified, live simulation running (still private)

- **12-month history complete** (not regenerated): 24,313 orders, 280 returns, 573 deliveries, 724 register
  sessions, paid sales $870,891.93 ([TEST_RESULTS](TEST_RESULTS.md#pos-m6--nexopos-dataset-live-simulation-visitor-showcase-2026-11-18-local-acceptance)).
- **43/43 integrity checks pass** on the live database after fixing what the baseline found: 23 fully returned
  promotional orders left at a negative total by NexoPOS's flat-discount refresh (engine rule + idempotent
  `hp:repair-refunds`; register chain restored) and setup/customer creation dates (chronology). Replay over the
  full year: 26,754 = 26,754 events.
- **Lookup indexes** (module migration, indexes only): integrity 23 min → 26 s; repair 139 s → 15 s.
- **Live worker** running as a service: catch-up, recycle (exit code 3 → restart), pause across a due sale,
  service restart during trading — no loss, no duplicate. Recovery suite on a clone (concurrency, mid-day kill) passes.
- **Browser tests:** isolated admin 8/8 on a clone; visitor 4/4 on the real data, 0 records written by the visitor.
  Screenshot review fixes: upstream ads hidden for the visitor, compact phone banner.
- **Backup/restore** verified as SYSTEM via the scheduled task, with row counts and text checksums; a restore
  encoding defect (PowerShell re-encoding the dump) found and fixed in three scripts.
- **Resources** measured with CRM, Práctica and the worker running: hosted services < 1 % of one core in total,
  POS loopback pages ~0.3 s median, CRM/portal/Práctica public 60–100 ms median.
- **POS remains private**: public activation awaits the owner's authorization (POS-PUBLIC).

## 2026-11-18 — Shared hosting: owner's Práctica application verified alongside the portfolio (D-016)

- Owner-authorized reactivation verified end to end:
  - services on automatic start, running;
  - database reachable, 0 check issues, no pending migrations;
  - public HTTPS with a trusted certificate;
  - sign-in and CSRF working, static assets served, admin protected;
  - loopback-only bindings.
  Nothing was reset, migrated or re-credentialed.
- Portfolio unaffected:
  - CRM public endpoints 200;
  - POS still non-public;
  - the POS 12-month backfill kept running throughout (no restart).
- POS (in progress, pushed):
  - visitor checkout preview on the real POS screen;
  - catalog artwork;
  - setup-record chronology;
  - replay determinism check (30 days: 2,602 = 2,602, 0 mismatches);
  - health endpoint;
  - deadlock retry;
  - guarded public-activation script (not run);
  - nightly backup task.
- M7: portal source written (not deployed).

## 2026-11-18 — M6 in progress: Harbor & Pine Market engine built; 12-month history generating

- **Checkpoint reconciled** (M4 done, M6 active, pending/blocked lists corrected).
- **Retail engine** as NexoPOS module `HarborPine` (GPL-3.0): catalog, deterministic day plans, idempotency
  ledger, deliveries, registers, sales with discounts/tax/cash+card, returns, waste/shrink — all through NexoPOS
  services ([POS_DATA_ENGINE.md](POS_DATA_ENGINE.md)). Trial (8 days, 575 orders): **41/41 integrity checks pass**.
- **Performance:** cold start 41 s → 2.7–3.8 s (Laravel optimize); backfill 2.5 s → 0.75 s per sale after
  deferring per-order dashboard recomputation and stopping a runaway Defender scan that held 2 of 3 cores.
- **Running now:** detached 12-month backfill (~55 s per store day, ~6 h).
- **Built, not yet deployed/tested:** read-only visitor mode with checkout preview, live worker service,
  MariaDB backup with restore check, isolated-clone E2E runner + specs, public HTTPS site (inactive).
- **CRM follow-ups:** test accounts kept (audit history); public E2E reuses one invitee (no accumulation, verified);
  unattended live-lead observer scheduled for the next business window (2026-11-18 14:05 UTC).

## 2026-11-17 — M4 done: CRM deployed with live synthetic operations and read-only visitor access

- **Live:** `https://crm.<VPS_IP>.sslip.io` runs the M4 build; 13-month history (499 companies, 312 deals,
  $2.07 M won) generated in production; 22/22 integrity checks; live simulation worker on (intensity 3).
- **Visitors:** "Explore the live demo" gives a credential-free, read-only session (D-014), viewing as the busiest rep.
- **Public E2E 10/10**; acceptance walkthrough defects fixed (see TEST_RESULTS).
- **Pending observation:** first live lead during a production business window (14:00–24:00 UTC).
- **M6 started:** PHP 8.3.36 + MariaDB 11.8.10 (`portfolio-pos-mariadb`, 127.0.0.1:3307) installed and verified;
  NexoPOS v6.3.0 installed against it (not yet routed publicly).

## 2026-11-17 — CRM M4: features complete in code, Supabase removed, data engine running (not yet deployed)

- **Owner decision D-013:** no rebuild; development resumed. F11 closed (owner's own tool). Incident stays open (R-014).
- **API:** global search (ported `global_search`), team management with invitations and one-time password links
  (no email service: links shown to the admin), first-run sign-up, contact merge in one transaction, private
  attachments, SSE live updates, deal-category search. 38/38 backend tests.
- **Frontend:** all portfolio provider methods implemented (no "not available" stubs left); Supabase provider,
  components and packages removed; live updates on every page; honest messages (no "email sent").
- **Data engine:** ~500 curated values, event-driven B2B sales model, deterministic reset/replay, live worker,
  21 integrity checks — 13 months generated in 25 s with 0 violations ([CRM_DATA_ENGINE.md](CRM_DATA_ENGINE.md)).
- **Browser e2e:** 5/5 on a local stack.
- **Not done:** the live deployment still runs the PoC build — redeploying (migrations 0002–0003, new build,
  synthetic data, live simulation) awaits owner confirmation; visitor/showcase access model; M4 acceptance on the public URL.

## 2026-11-17 — Security investigation: confirmed malware (project paused on host)

- The suspicious task traced back to an executed information-stealer loader (2026-10-07) delivered via a password-protected "setup package" archive; payload is an obfuscated Python script disguised as `app.asar`; hidden logon persistence. Defender never detected it.
- No current malicious process, connection or other persistence found; task disabled, second stage gone.
- Sanitized report: [SECURITY_INVESTIGATION.md](SECURITY_INVESTIGATION.md); raw evidence kept locally (restricted).
- **Paused:** new deployments and CRM M4 work on this host (D-012) until the owner rotates credentials and chooses rebuild vs. in-place remediation.

## 2026-11-17 — CRM PoC passed: Atomic CRM running on our own API + PostgreSQL (M4 started)

- **Backend:** Fastify API with app-managed auth, CSRF/origin checks, rate limiting, lockout, server-side filter translation, record-level rules and an audit log, over a dedicated PG16 cluster (D-010). 15/15 tests.
- **Frontend:** pristine upstream snapshot committed separately; portfolio data/auth providers swapped in with 2 import changes; upstream FakeRest demo provider compiles unmodified.
- **Live:** `https://crm.<VPS_IP>.sslip.io` — Windows service under LocalService, Caddy route, CSP/HSTS. Playwright 2/2 in a real browser; audit log confirms the persisted sequence.
- **Ops:** nightly CRM backup with restore verification (SYSTEM scheduled task, result 0x0). Secrets split so the service can't read superuser credentials.
- **Not done yet (M4):** sign-up, team management, password reset, global search, merge, attachments, SSE, Supabase package removal, data generator, visitor access model. The CRM is live but **empty** and only the admin can log in.

## 2026-11-17 — Host consolidation done; portfolio HTTPS live (M3 partial)

- Owner decisions D-008 (retire four unrelated sites) and D-009 (CRM without Supabase) recorded; D-007 superseded.
- Four sites retired reversibly: Caddy routes removed via validated graceful reload, three services stopped and Disabled, data untouched, host-side backups + restore script. Verified unreachable over HTTPS.
- `https://portfolio.<VPS_IP>.sslip.io/healthz` → 200 with a publicly trusted certificate (M3 acceptance criterion met; logging/backup/health scripts still pending).
- Resource finding: the retired sites used only ~100 MB; the host's pressure comes from interactive tooling (R-013). Working budget ≈3.9 GB RAM, 17.6 GB disk.

## 2026-11-17 — M1 complete, M2 inspection complete → awaiting owner decisions

- **M1:** audited all four upstreams from source + GitHub API ([UPSTREAM_AUDIT.md](UPSTREAM_AUDIT.md)). Licenses verified (one upstream inconsistency: NexoPOS `composer.json` says MIT, LICENSE says GPL-3.0 → GPL-3.0 applied). Pins chosen (D-005). Simulator integration points identified with file/line references (D-006).
- **M2:** nested virtualization **confirmed unavailable** (kernel API). sslip.io DNS verified for all four hostnames. Public HTTPS via sslip.io proven on this host by an existing Caddy site (trusted cert, 308 redirect). Native runtime strategy proposed (D-007).
- **Stopped before any VPS modification.** Next steps install software on a shared production host and need a reboot (WSL feature) and a change to the shared Caddyfile; both require owner approval. See checkpoint `owner_decisions_needed`.

## 2026-11-17 — M0: repository created

- Created public repo `Witcher-Geralt-of-Rivia/elite-business-systems-portfolio`; verified visibility, default branch, Issues, Actions, initial commit, write access (see TEST_RESULTS.md §M0).
- Added tracking structure: README, CLAUDE.md, LICENSE (MIT, original work only), `.gitignore`, docs/*, `state/checkpoint.json`.
- Read-only host inspection performed early because the agent turned out to be running on the VPS itself. Findings recorded (sanitized) in ARCHITECTURE.md §3 and RISKS.md R-001..R-006. Most significant: virtualization extensions appear unavailable to the guest OS, which would rule out WSL2/Docker. Not yet conclusively confirmed.
- **Not done yet:** no upstream code cloned; no VPS changes made.
