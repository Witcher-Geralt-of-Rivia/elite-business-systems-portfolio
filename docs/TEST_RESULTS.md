# Test Results & Evidence

Only results actually executed are recorded here. Each entry: date · milestone · what was checked · command/tool · result.

## M0 — Repository creation

| Date | Check | Method | Result |
|---|---|---|---|
| 2026-11-17 | Authenticated GitHub identity | `gh auth status`, `gh api user` | `Witcher-Geralt-of-Rivia` (User), scopes `repo, workflow, read:org, gist` |
| 2026-11-17 | Name availability | `gh api repos/<owner>/elite-business-systems-portfolio` | 404 before creation (name free) |
| 2026-11-17 | Repository created | `gh repo create … --public --add-readme` | https://github.com/Witcher-Geralt-of-Rivia/elite-business-systems-portfolio |
| 2026-11-17 | Visibility | `gh api repos/…` → `visibility` / `private` | `public` / `false` |
| 2026-11-17 | Default branch | `gh api repos/…` → `default_branch` | `main` |
| 2026-11-17 | Issues enabled | `gh api repos/…` → `has_issues` | `true` |
| 2026-11-17 | Actions enabled | `gh api repos/…/actions/permissions` | `enabled: true` |
| 2026-11-17 | Initial commit exists | `gh api repos/…/commits` | `bcae897` "Initial commit" |
| 2026-11-17 | Write access | `gh api repos/…` → `permissions` | `admin/push: true` |
| 2026-11-17 | Tracking structure pushed | `gh api repos/…/commits/main` | `16dc51f` with all 15 files listed |
| 2026-11-17 | README publicly readable | unauthenticated `curl` of raw README | HTTP 200 |

## M2 — Windows VPS compatibility (read-only inspection)

| Date | Check | Method | Result |
|---|---|---|---|
| 2026-11-17 | OS edition/build | `Win32_OperatingSystem` | Windows Server 2025 Standard, build 26100 |
| 2026-11-17 | Host is a VM guest | `Win32_ComputerSystem` | Model "Virtual Machine", `HypervisorPresent=True` |
| 2026-11-17 | Virtualization exposed to guest | kernel32 `IsProcessorFeaturePresent(21 VIRT_FIRMWARE_ENABLED, 20 SLAT)` | **False / False** → no nested virtualization |
| 2026-11-17 | WSL / VirtualMachinePlatform | `Get-WindowsOptionalFeature` | both Disabled (WSL2 impossible regardless; WSL1 would need feature + reboot) |
| 2026-11-17 | Docker | `Get-Command docker` | not installed |
| 2026-11-17 | CPU / RAM / disk | CIM + `Get-PSDrive` | 2 cores / 3 logical; 12 GB RAM, ~5.8 GB free; ~18 GB free on C: |
| 2026-11-17 | Native runtimes present | `Get-Command` | Node 24.19, Python 3.13; no PHP, MySQL/MariaDB, Redis |
| 2026-11-17 | sslip.io DNS | `Resolve-DnsName {portfolio,crm,erp,pos}.<VPS_IP>.sslip.io` | all 4 resolve to the VPS public IP |
| 2026-11-17 | Existing reverse proxy | service inspection | Caddy (Windows service) on public IP :80/:443, per-site blocks appended to one Caddyfile, file-system cert storage |
| 2026-11-17 | Public HTTPS via sslip.io on this host (pre-consolidation) | `curl -I https://<existing-site>.<VPS_IP>.sslip.io` | HTTP 200, `ssl_verify_result=0` (publicly trusted cert); HTTP→HTTPS 308 redirect |

## Consolidation (D-008) — 2026-11-17

| Check | Method | Result |
|---|---|---|
| Pre-change backups | config copies, service definitions, scheduled-task export, static site copy; data copies taken after stop; owner's own DB backup task run on demand | OK — DB dump + media archive with SHA-256 files; host-side backup dir restricted to Administrators/SYSTEM |
| New host Caddyfile | `caddy validate` on staged file, then on live file | `Valid configuration` |
| First reload attempt | `caddy reload` | **Rejected** (HTTP 400: Caddy service account could not open the new log dir). Running config unchanged — no outage. Fixed by granting `NT SERVICE\caddy` least-privilege ACLs. |
| Second reload | `caddy reload` | exit 0, service Running |
| Retired services | `Stop-Service`, `Set-Service -StartupType Disabled`, listener check | 3 services Stopped/Disabled; no listeners left on their ports |
| Retired hostnames unreachable | `curl https://<site>.<VPS_IP>.sslip.io` ×4 | TLS handshake refused (no cert served), HTTP only yields Caddy's generic 308 → HTTPS failure. No content reachable. |
| Portfolio over HTTPS (M3 acceptance) | `curl https://portfolio.<VPS_IP>.sslip.io/healthz` | `ok`, HTTP 200, `ssl_verify_result=0` (publicly trusted cert issued on first request) |
| Portfolio HTTP→HTTPS | `curl http://portfolio…/` | 308 → https |
| Resources recovered | process working sets before stop; free RAM/CPU/disk before vs after | Retired sites' process trees held **~100 MB** RAM; net free RAM change was within noise (−336 MB, other processes grew). CPU load (73–97%) and RAM pressure come from interactive tooling on the host (editor ≈3.2 GB across 27 processes, desktop AI/remote-access clients ≈1.2 GB, antivirus). Disk unchanged (no deletion, by design). Free: ~3.9 GB RAM, 17.6 GB disk. |

## CRM backend PoC (D-009) — 2026-11-17

Environment: dedicated PostgreSQL 16 cluster `portfolio-crm-postgres` (127.0.0.1:5433), database `crm_test`, role `crm_app` (DML only). Fastify 5.12.8, pg 8.23.1, Node 24.19 (type-stripping, no build step). `tsc --noEmit` clean.

Command: `node --env-file=<secrets>/crm-test.env --test --test-concurrency=1 test/*.test.ts` → **14/14 pass** (first run 11/13: two test defects fixed — wrong expected type for int8, and lockout test was pre-empted by the login rate limiter; split into two tests).

| Area | Verified behaviour |
|---|---|
| Auth | 401 without session; generic error for wrong password / unknown email; failed logins audited; login refused without CSRF header or from a foreign Origin; cookie `HttpOnly; Secure; SameSite=Lax`; only sha256 of the token stored; logout revokes server-side |
| CRUD workflow | company → contact (jsonb emails/phones, tag array) → deal (array columns) → contact note (jsonb[] attachments) → task; computed view columns (`nb_contacts`, `company_name`, `nb_tasks`) correct and ignored on write; deal stage/amount update bumps `updated_at` |
| Filters | `q` search across view columns, `@or` + `@ilike`, `@cs` array contains, `@is null`, `in` (getMany), sort + order |
| Persistence | values re-read on an independent connection |
| Audit | create/update/delete rows written in the same transaction as the change |
| Permissions | sales rep reads team data, cannot edit/delete others' records, cannot create for or reassign to others; showcase visitor read-only; team members not writable via generic API; auth tables not exposed |
| Input safety | unknown filter field / operator / sort column → 400 (never interpolated); login rate limit → 429; account lock after 5 failures even with the correct password |

### CRM PoC — browser, live deployment (2026-11-17)

Stack under test: Atomic CRM UI (upstream snapshot + portfolio providers) → Caddy (HTTPS, sslip.io, publicly trusted cert) → `portfolio-crm-api` Windows service (LocalService) → `portfolio-crm-postgres`.

| Check | Method | Result |
|---|---|---|
| Public endpoints | `curl https://crm.<VPS_IP>.sslip.io/...` | `/api/health` 200 (`ssl_verify_result=0`); SPA 200; unauthenticated `/api/r/contacts` 401; HSTS, CSP (`script-src 'self'`), X-Frame-Options, nosniff present |
| Browser E2E | `npx playwright test -c playwright.portfolio.config.ts` (Chromium 1.64) | **2/2 pass**: wrong password → 401 and stays on login; login via UI → dashboard, cookie `HttpOnly`+`Secure`; company created through the real form (201) → visible after reload → API update reflected in UI → deleted → logout redirects to login |
| DB-side confirmation | `crm.audit_log` | `login_failed`, `login`, `create companies 1 (Bergen)`, `update (Stavanger)`, `delete`, `logout`; 0 companies left behind |
| Backend suite | `node --test` against `crm_test` | **15/15 pass** (adds configuration read/write permissions and a production-budget rate-limit test) |
| Backup | `backup-crm.ps1 -VerifyRestore`, scheduled task as SYSTEM | dump + sha256 written; restore into scratch DB, row counts identical; task result 0x0 |

Failures encountered on the way (all fixed, none were product defects in the final state): missing `CHANGELOG.md` in the snapshot broke the Vite build; three deploy scripts aborted on harmless native stderr under Windows PowerShell 5.1; the browser test first used path URLs although the app uses hash routing with relative assets, then guessed the wrong button label.

## CRM M4 — backend features (2026-11-17)

Command: `node --env-file=<crm-test.env> --test --test-concurrency=1 test/m4.test.ts test/poc.test.ts` against `crm_test`
(migration 0002 applied). **31/31 pass** (15 PoC + 16 M4).

| Area | Verified behaviour |
|---|---|
| First run | empty instance accepts exactly one sign-up → admin; second sign-up 403; weak password 400 |
| Invitations | admin-only; account created without password; one-time link (72 h) sets password once; raw token never stored; duplicate email → 409 `email_taken` |
| Team rules | reps can edit only their own profile, cannot change roles/disable; last active admin cannot be demoted/disabled; disabling ends sessions immediately |
| Password links | newest link only; set-password resets lockout and revokes all sessions |
| Global search | accent-insensitive prefix search across 6 resources (ported `global_search`), resource filter, blank query → `[]`, 401 when signed out; `fts` never leaked |
| Merge | one transaction: tasks/notes/deal links moved, fields merged per upstream rules, duplicate deleted, audited; self-merge 400, unknown 404, non-owner rep 403 with no side effects |
| Attachments | private storage under server-generated names; path components stripped; download requires session; non-images forced to download with `sandbox` CSP + nosniff; CSRF enforced; orphan purge keeps referenced files |
| Live updates | SSE stream 401 when signed out; committed deal update delivered as `change` event |

Bug found and fixed by these tests: `bigint[]` columns (`deals.contact_ids`, `contacts.tags`) were returned as strings; now numbers.

## CRM M4 — frontend integration, Supabase removal, data engine (2026-11-17)

**Backend, all suites** (`test/poc.test.ts test/m4.test.ts test/simulation.test.ts`, crm_test, migrations 0001–0003): **38/38 pass**.

**Data engine** (`test/simulation.test.ts`, 4-month window): 7/7 — catalog size in range; backfill through
ResourceService with every write audited as `simulator`; 0 integrity violations; plausibility bands;
same seed + as-of → identical hash, different seed → different hash; 10 live ticks ≡ one uninterrupted
advance (same hash); live mode skips records deleted by users.

**Full 13-month backfill** (`npm run simulate -- reset --seed 20261117 --months 13 --as-of 2026-11-17T18:00:00Z`, crm_test):
25 s; 467 companies, 1,193 contacts, 295 deals (18 expansion), 1,799 notes, 1,282 tasks (168 open);
74 won / 177 lost (win rate 29.5 %), won revenue $2,203,500, median won deal $18,250; leads in every
month following the seasonal curve; open pipeline spread across all stages at as-of.
`simulate integrity`: **21 checks, 0 failing**. Data hash `54c76f29…2fed0`.

**Browser end-to-end** (Playwright/Chromium, `e2e-portfolio/crm-m4.spec.ts`) on a local stack: production
build via `vite preview` + API on loopback against crm_test (seeded by the engine), throwaway admin:
**5/5 pass** — global search opens the company; admin invites → one-time link dialog → invitee sets
password → signs in as sales_rep → link reuse refused (400); note attachment uploaded and downloaded
byte-identical; a teammate's note appears on an open page without reload (SSE); duplicate contact merged
through the UI dialog (history moved, duplicate gone).
Two first-run failures were test defects (merge lives on the edit page; search picked a contact whose
subtitle is the company) — fixed in the spec, not the app.

**Frontend**: `tsc` clean; Vitest `scripts` project 4/4 (runtime config). Supabase packages absent from
`package.json` and `package-lock.json`.

## CRM M4 — production deployment and public acceptance (2026-11-17)

**Rollout:** repo state verified clean and pushed → `pg_dump` backup + restore check into a scratch DB
(row counts matched) + copy of the previous API/UI folders and env file → migrations 0002/0003 applied →
build deployed (same hostname, Caddy site, Windows service) → 13-month history generated → integrity → public tests.
Two deploy-script defects surfaced and were fixed (WinSW wrapper copied while the service ran; WinSW 2.x has no
`refresh`); the service was restarted within about a minute and the previous version stayed restorable throughout.

**Production dataset** (seed 20261117, 13 months to deploy time, 31 s): 499 companies, 1,265 contacts,
312 deals, 81 won / 180 lost (win rate 31.0 %), won revenue $2,070,500, 1,851 notes, 1,335 tasks (64 open).
`simulate integrity` on the production database: **22 checks, 0 failing**; weekend activity share 0.

**Public HTTPS browser tests** (`https://crm.<VPS_IP>.sslip.io`, Chromium): **10/10 pass**:
PoC 2/2 (login refusal; create, persist, update, delete through the UI), M4 5/5 (search, invitation with
one-time link, first sign-in, link reuse refused, attachment round trip, SSE live note on an open page, UI merge),
showcase 3/3 (visitor session without credentials; dashboard chart, hot contacts, tasks and activity rendered;
pipeline, companies, contacts, contact record; save attempt refused with the read-only message and nothing stored;
users/config/upload refused 403 `showcase_read_only`; sign-up 403; phone viewport; no uncaught page errors).
After each run a cleanup step removes test records and verifies no test account can sign in (`loginable_test_accounts = 0`).

**Acceptance walkthrough findings fixed before sign-off** (screenshots reviewed on desktop and phone): visitors hit
"Access denied" on dashboard/contact pages; contacts dated in the future and on weekends; repetitive company and
deal names; generic title; empty personal widgets for visitors; banner covering the phone navigation;
a year of stale overdue tasks; losses dominating the revenue chart. Fixes: 34e0b1c, f4f6cdc, 52f7cbc.

**Operational checks**

| Check | Result |
|---|---|
| Restart preserves simulation state | clock continued 02:36:31 → 02:38:24 across a service restart; queue 159 → 159; data hash identical before/after (no duplicate events) |
| Live worker running | `live simulation enabled` (tick 60 s, intensity 3); clock advances every minute |
| New leads in production | **observed 2026-11-18** (unattended observer, 14:05–21:00 UTC): the engine's one scheduled lead for the day (planned 20:48:48 UTC) arrived as company 501 with 3 contacts, an intro note and a first task, owned by its regional rep. All 7 records were audited as `simulator` at 20:49:42 (worker tick), and the SSE insert reached the subscribed client 59 ms after commit. 23 change events and 0 SSE errors in the window. See the M8 section |
| Admin records protected | visitor writes refused at HTTP and service layers; the simulator never touches the administrator account |
| Resources | API 81 MB RAM, 9 CPU-s since start; CRM PostgreSQL ~110 MB; pgdata 166 MB; backups 18 MB; host free RAM 4.0 GB, disk 15.3 GB |
| API latency (visitor, public URL) | 0.10–0.32 s per list request on an idle host; up to 2.5 s while a test browser saturated the 3-CPU host |

Once, a combined backend run reported 15 cancelled tests (0 failed); not reproduced in three later runs.

## POS M6 — NexoPOS dataset, live simulation, visitor showcase (2026-11-18, local acceptance)

**12-month history** (seed 20261118, store days 2025-11-17 → 2026-11-17, generated through NexoPOS services in
32,407 s + report rebuild; never regenerated afterwards): 362 trading days (4 holiday closures), 24,313 orders /
67,000 lines / 24,313 payments (18,888 simulated card $683,428.04; 5,425 cash, tendered $242,769.00),
280 returns ($2,881.20), 573 deliveries (584 procurements, $447,697.96 at cost), 70,551 stock movements,
724 register sessions, 88 products in 12 categories, 11 suppliers, 421 customers; paid sales $870,891.93,
taxes $20,832.02, discounts $16,011.92; 368 day and 13 month reports; 26,754 ledger events; database ~100 MB.
Monthly orders: Nov* 985 · Dec 2,696 · Jan 1,423 · Feb 1,394 · Mar 1,724 · Apr 1,782 · May 2,148 · Jun 2,184 ·
Jul 2,388 · Aug 2,430 · Sep 1,879 · Oct 2,018 · Nov* 1,262 (*partial months).

**Integrity (43 checks)** — baseline right after the backfill: 4 failing.

| Check | Baseline | Cause | Fix | After |
|---|---|---|---|---|
| `refunded_order_status` | 23 | fully returned promotional orders: NexoPOS kept the flat discount → total −discount, status "paid" | engine: returned unit takes its discount share; `hp:repair-refunds` (refreshOrder, listeners off) | 0 |
| `register_balance_chain` | 14 | for those orders NexoPOS re-recorded the cash change at the refund day's balance (7 cash) and created change payouts for card orders (16) | change entries restored from the ledger; payouts removed, session rebalanced | 0 |
| `product_created_after_first_sale` | 88 | setup ran on the real clock | `hp:presentation` chronology | 0 |
| `customer_created_after_first_order` | 421 | same | same | 0 |

Rehearsed twice on a clone before touching the shared database (pre-change backup taken by the scheduled task).
Live result: **43/43 pass** (26 s with the new lookup indexes; 1,385 s before). Paid sales moved by exactly the
+$12.44 of the 23 negative totals; refunds, payments and stock unchanged. With live trading included (08:48):
43/43, 24,318 orders, dashboard paid sales = order paid sales ($871,056.25).
`hp:replay-check --days=400` (bounded at the scenario start): 366 days, 26,754 planned = 26,754 ledger,
0 missing / unexpected / time / kind mismatches.

Two further defects found while testing and fixed: a return made the original sale day's report stale (NexoPOS
only recomputes today) → stale-day marker + recompute after each run; the month report froze during simulated
runs → recomputed per processed day.

**Recovery suite on an isolated clone** (`run-pos-sim-recovery.ps1`, next store day 2026-11-19):
two engines on the same window → exit 0 / 1 (the loser aborted on a register race, its transaction rolled
back), settle run 0; engine killed mid-day after 15 events, recovery run 0, +40 events, watermark end of day;
replay 154 = 154; 0 duplicate order entries; 65 orders = 65 sale events; integrity 43/43.

**Live worker** (`portfolio-pos-sim`, LocalService, after deployment 07:07):

| Test | Result |
|---|---|
| Catch-up from the backfill watermark | deliveries 07:16 / 07:28 and register openings 07:50 / 07:51 processed on time; health lag 9–23 s |
| Planned recycle | exits with code 3 after `--max-minutes`; observed twice with a 2-minute setting, service restarted after 30 s / 60 s (a 0 exit would have stopped the service — fixed) |
| Pause / resume | paused 08:08:27–08:25:05: sale due 08:09:21 not processed, watermark frozen at 08:07:53; after resume processed at 08:25:55 with its business time |
| Service restart during trading | stopped 08:28–08:33; sales due 08:31:01 and 08:32:42 processed at 08:33:14; 0 duplicate ledger keys, 0 duplicate order entities, 3 orders = 3 sale events; replay (3 days) 136 = 136 |

**Browser tests** (Chromium, `run-pos-e2e.ps1`):
- *Isolated admin* (clone `nexopos_e2e`, dropped afterwards): **8/8** — wrong password refused and sign-in; register
  open with float + cash-in; API checkout decreases stock and records payment; POS-screen checkout with the
  simulated card; receipt, customer history and daily sales report include the sale; dashboard reflects it;
  one-item refund restocks and marks the order partially refunded; register close at the counted balance reconciles.
- *Visitor* (real dataset, read-only): **4/4** — entry without credentials and tour (dashboard, products, orders,
  customers, registers, sales report); checkout preview on the POS screen refused with the explicit message;
  writes, admin areas and report recomputation refused while reads work; phone viewport. Database check after
  the run: **0 records authored by the visitor**.
- Screenshot review (desktop 1280 px, phone 390 px) — fixed: upstream product ads shown to visitors (snoozed for
  the visitor account, also avoids the remote ad lookup); 4-line banner covering phone content (compact
  one-line form ≤ 640 px); dashboard captured before widgets loaded (test waits for real figures). Remaining,
  upstream look: abbreviated `$0.0` style in the three summary cards; "This week vs last week" is partial early in the week.

**Backup / restore** (`Portfolio - POS nightly backup`, SYSTEM, 03:45 daily, triggered manually at 07:03):
dump 103.3 MB + SHA-256; restore into a scratch database; row counts equal for 7 business tables; text checksums
equal for products, categories, registers, users and order codes; scratch dropped; task result 0.
Defect found and fixed: restores piped the dump through PowerShell 5.1, which re-encodes non-ASCII text
("Café" → "CafÃ©") while row counts still matched — now the client reads the file, and the content checksum
catches such corruption. The same fix applied to the recovery suite and the E2E clone.

**Resources** (`measure-resources.ps1`, 10 min at 08:35 with CRM, Práctica and the POS worker running):

| Item | Value |
|---|---|
| Host | CPU avg 17.9 % / p95 25.5 % (3 vCPU) — dominated by the remote-desktop session (RustDesk ~48 % of one core, desktop compositor ~10 %), not by hosted services; RAM 6.8 / 12 GB; C: free 14.2 GB |
| POS services | MariaDB 65 MB / 0.2 % core; PHP-FastCGI ×2 3 + 36 MB / 0 %; simulation worker 113 MB / 0.5 % core |
| CRM services | API 40 MB / 0 %; PostgreSQL 23 MB / 0 % · Caddy 23 MB / 0.3 % · Práctica 4 + 29 MB / 0 % |
| Disk | POS app 97 MB, MariaDB data 307 MB, POS backups 310 MB (3 dumps today), PHP 88 MB, CRM 175 MB |
| Latency (20 sequential requests) | POS loopback `/sign-in` median 321 ms / p95 401 ms; `/harborpine/health` 335 / 424 ms; CRM public `/api/health` 67 / 129 ms, `/` 59 / 133 ms; portal `/healthz` 61 / 195 ms; co-hosted application sign-in page 102 / 183 ms |

Working-set figures are as reported by Windows (trimmed pages excluded).

**Not done at local acceptance (owner decision):** public HTTPS activation of the POS (`activate-pos-public.ps1 -OwnerApproved`); done later the same day, see [POS M6 — public activation](#pos-m6--public-activation-2026-11-18-d-017).

## M7 — Portfolio portal deployment (2026-11-18)

**Deployment** (`deploy-portal.ps1`, graceful `caddy reload`, host Caddyfile unchanged — SHA-256 identical before
and after): staged with `crm=live, pos=preparing`; smoke tests passed (home 200 with CSP, `config.js` as written,
`/status/crm` → `{"status":"ok"}`, `/status/pos` → 404 while the POS is private, CSS/JS/screenshots 200).
Re-rendered CRM/POS site files differ from the previous ones only by a comment character (renderer now reads
templates as UTF-8; the em dash had been written as `â€”`).

**Neighbours after the reload:** CRM `/api/health` and `/` 200, co-hosted application sign-in page 200, POS loopback health 200,
no public POS site.

**Browser check** (Chromium, desktop 1366 px and phone 390 px, public URL): 0 page/console/request errors,
no horizontal scroll (scrollWidth = viewport), CRM links point to the CRM public host, POS links disabled with
"soon", live status `crm: operational`, `pos: being finalised`, `erp: in preparation`, both screenshots loaded.
Headers: CSP `default-src 'self'` (no external resources), HSTS, `X-Robots-Tag: noindex, nofollow`.

Screenshots: CRM from the public read-only showcase; POS from the read-only visitor session on the real dataset
(`apps/pos/e2e/portal-shots.spec.ts`, cart in the browser only, nothing submitted).

Prepared for the POS approval and validated offline (`caddy adapt`): portfolio site with `/status/pos`, and the
POS public site keeping a loopback listener that serves only `/harborpine/health`.

## POS M6 — public activation (2026-11-18, D-017)

**Before activation** (10:28 local):
- health `ok` (worker running, lag 1 s);
- all POS services, Caddy and the CRM running;
- production `.env` (`APP_ENV=production`, `APP_DEBUG=false`, secure session cookie, session/Sanctum domain = public
  host);
- CRM, portal and Práctica public endpoints answering;
- the POS public hostname not served;
- host Caddyfile SHA-256 `f606ec68…89b6`.

**First run aborted safely in preflight:**
- The script reported "integrity: 8 failing checks" although all 43 checks returned 0.
- Cause: `hp:integrity --json` encodes "no failures" as `[]`. The script counted the PowerShell properties of
  that empty array (`Length`, `Rank`, …), so it saw 8.
- The abort happened before any change: no flag, no backup, no reload.
- Fixed by treating an array as zero failures and naming failing checks otherwise (both shapes unit-checked).
  The script also now refuses a run with fewer than 43 checks.

**Activation run** (`activate-pos-public.ps1 -OwnerApproved`, 10:30–10:33):

| Step | Result |
|---|---|
| Preflight | services, production `.env`, visitor mode, **integrity 43/43** |
| Backup | `pos-20261118-103036.sql`, 103.4 MB, with SHA-256. Restored into a scratch database: row counts equal for orders 24,325, lines 67,036, payments 24,325, products 88, procurements 586, register history 31,195, stock history 70,598. Text checksums equal for products, categories, registers, users and order codes |
| Publish | approval flag written; site files rendered; whole host Caddyfile `Valid configuration`; graceful `caddy reload` |
| Smoke | HTTPS sign-in 200, HSTS, `Secure` session cookie, visitor entry on the sign-in page, hidden files not exposed |
| Public visitor suite | **4/4** against `https://pos.<VPS_IP>.sslip.io`; **0** records authored by the visitor |
| Portal | redeployed with `crm=live, pos=live`; `/status/crm` ok; `/status/pos` 200 |

**After activation** (independent checks):

TLS and transport:
- Let's Encrypt certificate, chain valid, SAN matches the host, TLS 1.3, valid until 2027-02-16.
- HTTP → HTTPS `308`.
- Headers: HSTS, `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`,
  `Referrer-Policy: strict-origin-when-cross-origin`.
- `nexopos_session` cookie is `secure; httponly; samesite=lax` and scoped to the POS host.

Access control:
- Wrong credentials on `POST /auth/sign-in` → 403 "Invalid username or password."
- `/dashboard` without a session → 302 to `/sign-in`; `/api/orders` without a session → 401.
- `/sign-up` → 403 (registration disabled).
- `/.env`, `/storage/logs/laravel.log` and `/composer.json` → 404.

Visitor write restrictions, from the suite:
- The order POST is refused with the checkout-preview message, and product create, report recompute,
  register open and bulk delete are refused with 403 `showcase_read_only`.
- User management and settings are refused; read-only report queries are allowed.
- The database shows 0 visitor-authored records after every run.

Worker:
- 0 duplicate event keys and 0 reused non-register entities. The two cash registers are reused by design: they open
  and close daily.
- 13 orders today = 13 sale events.
- A sale due at 10:39:58, after activation, was recorded at that second.
- Health lag 36–58 s.

Neighbours:
- CRM `/` and `/api/health` 200.
- Práctica 302 to its sign-in.
- Portal 200; `/status/crm` 200.

Caddy:
- Host Caddyfile SHA-256 unchanged, last written 02:08 before activation.
- The Caddy process start time is unchanged (2026-11-09): the service was reloaded, not restarted.

Laravel log since activation: only the probe's own refused sign-up and wrong-password attempt.

**Screenshot review (public):** three capture problems found and fixed.

| Screenshot | Problem | Fix |
|---|---|---|
| Phone dashboard | Taken before the summary cards loaded ($0.0) | The spec waits for the six-figure card values, as on desktop |
| Checkout preview | Taken while the payment popup's spinner showed | A probe measured the snackbar fully above the banner (message bottom y = 659, banner top y = 679) for about 3 s. The spec now asserts that and waits for the spinner |
| Phone footer | The upstream "You're using NexoPOS 6.3.0" credit sat under the demo banner | Visitor-only CSS lifts it above the banner; the spec asserts no overlap |

After deploying the module change, the suite was re-run against the public URL: **4/4**, 0 visitor records.
The screenshots were reviewed again: real figures on the phone dashboard, the refusal message visible, and the
footer credit clear of the banner.

**Portal browser check** (Chromium, 1366 px and 390 px, public URL):
- 0 page, console or request errors; no horizontal scroll; all images loaded.
- Status: `crm: operational`, `pos: operational · simulation live`, `erp: in preparation`.
- The POS buttons ("Explore the POS", "Open the read-only demo") link to `https://pos.<VPS_IP>.sslip.io/sign-in`.

## M8 — integration, performance and operational validation (2026-11-18, public POS)

Every change below went through the module (`deploy-pos-module.ps1`) or the guarded Caddy render
(validate, then graceful reload; host Caddyfile SHA-256 unchanged; Caddy process start time unchanged).

**1. Installed-state race (critical for visitors) — fixed.**
- **Symptom:** a public visitor run failed with an empty POS catalogue ("no products and no categories").
  The trace showed `GET /api/pos/catalog/categories` → 302 `/do-setup` → 403.
- **Cause:** upstream deletes the cached "installed" flag after every API/dashboard response, and
  `Helper::installed()` reads it with `has()` followed by `get()`. The same race made app boot fail 3 times today
  ("ModulesService::$options must not be accessed before initialization" → 500).
- **Reproduction before the fix:** 1 redirect in 348 parallel API calls; 2 in about 3,000 test requests
  (access log).
- **Fix:** the upstream listener is replaced, keeping the permission-cache clearing (verified: the
  `ResponseReadyEvent` listener list holds only the module's listener). A middleware fallback asks the database
  before redirecting and logs `installed-state cache race avoided`.
- **After the fallback alone:** 0 redirects in 614 calls, and the fallback fired once, on the catalogue endpoint.
- **After the listener change:** 0 redirects and 0 log entries in 623 calls (6 parallel visitor sessions,
  150 s). No ModulesService errors since.

**2. Telemetry opt-out.**
- Upstream posts the version, the enabled modules and the request host name, which contains the server
  address, to the vendor daily. It was failing only for lack of a CA bundle.
- Now answered locally for signed-in sessions; anonymous calls get 401.
- New admin E2E test 9 verifies the local answer. No "Telemetry failed" since deployment.

**3. Translation file.** `/lang/en.json` returned 404 for every page: the `public/lang` junction target lacked
Caddy read access. Granted read on that folder only, and codified in `configure-pos-app.ps1`; the file is now
served (200, 250 KB JSON).

**4. Visitor background calls.**
- Onboarding tours return an empty list for visitors; before, a 403 on every page.
- The vendor marketplace API and OAuth pages are refused for visitors (defence in depth).
- The visitor suite now fails on any 4xx/5xx response while browsing. Currently there are none.

**5. Security headers (POS).** Added
`Content-Security-Policy: frame-ancestors 'self'; object-src 'none'; base-uri 'self'; form-action 'self'`, on top
of HSTS, nosniff, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy` and `X-Robots-Tag`. NexoPOS needs inline
scripts, so there is no `script-src`. A browser sign-in attempt under the policy shows the rejection message with no
CSP violations.

**6. Test robustness.**
- Two upstream UI timing branches made POS-screen tests flaky: a lost early category click, and a
  "Select Customer" popup on Pay. Both are handled in the shared helpers `addToCart` and `openPayment`.
- After the fixes: admin isolated **9/9 twice**, public visitor **4/4 twice**, 0 visitor records. The log holds
  only the suites' deliberate wrong-password attempts.

**7. Known limitation (kept).** NexoPOS's API rate limit (80 requests/min per client) answers with HTTP 500
"Too Many Attempts" instead of 429. Normal browsing stays far below it.

**8. Dependency licences and vulnerabilities.**
- **Repository structure:**
  - upstream trees are git-ignored (0 tracked files);
  - the repo root is MIT; the NexoPOS module carries GPL-3.0; the CRM frontend snapshot keeps Atomic CRM's MIT.
- **CRM runtime licences** (`npm ls --omit=dev`):
  - Backend: 66 packages, all MIT/BSD/ISC.
  - Frontend: 254 packages, permissive except Inter (OFL-1.1, bundling allowed with notice), DOMPurify (MPL-2.0 or
    Apache-2.0) and lightningcss (MPL-2.0, an unmodified build tool). No GPL/AGPL.
- **`npm audit --omit=dev`:** CRM backend 0, CRM frontend 0, POS E2E tooling 0.
- **`composer audit` of NexoPOS v6.3.0's lock** found advisories in 11 packages, including Laravel 12.62, Symfony
  7.4.13/14, Guzzle, CommonMark, Dompdf and PhpSpreadsheet.
  - The critical Laravel TokenGuard bypass is **not reachable** here: the `api` token guard is configured but
    unused, and Sanctum consults only `web`.
  - Request-path advisories (a Symfony header ReDoS, the Laravel relationship-inclusion range) apply to a public
    site, so the packages were updated.

**9. PHP dependency security update** (`update-pos-dependencies.ps1`):
- **Stage:** a staging copy got `composer update <11 packages> -W --no-dev` inside NexoPOS's own constraints
  (Laravel 12.62.0 → 12.73.0, Symfony → 7.4.22/23, Guzzle 7.12.3 → 7.16.3, CommonMark 2.8.2 → 2.10.7,
  Flysystem 3.35.1 → 3.36.0, Dompdf 3.1.5 → 3.1.6, PhpSpreadsheet 5.8.1 → 5.11.0, Carbon 3.13.0 → 3.15.1).
  `composer audit`: **no advisories**.
- **Verification on staging:**
  - Admin isolated: **9/9**.
  - Visitor: **4/4**, 0 records.
  - Simulation recovery suite: **passed**.
    - Concurrency exits 1/0 with settle 0; crash after 19 events, recovery 0, +40 events.
    - Replay 154/154. The test day produced 65 orders = 65 sale events, the same as before the update, so the
      newer Carbon kept the engine deterministic.
    - 0 duplicates; integrity 43/43.
- **Promote (132 s):**
  - Worker and PHP workers stopped (public POS unavailable for about a minute).
  - Staged `vendor` copied into the app tree, so it inherits the LOCAL SERVICE read permission (verified), then
    swapped.
  - Caches rebuilt, services restarted. Health ok, integrity **43/43**, previous tree kept as `vendor.prev`
    (not web-reachable: 404).
- **Live afterwards:**
  - `composer audit`: no advisories; `artisan --version` 12.73.0.
  - Public visitor suite **4/4**, 0 visitor records.
  - Worker caught up: 25 orders = 25 sale events, 0 duplicate keys or entities.
  - CRM, portal and Práctica reachable.

**10. Monitoring** (`monitor-portfolio.ps1`, scheduled as SYSTEM every 15 minutes):
- First runs: all **10 checks ok** (CRM/POS/portal health, 3 TLS certificates with 89–90 days left, 7 services,
  both backups with checksums and task result 0, 14.2 GB free).
- The SYSTEM task run returned 0.
- A forced failure (impossible disk threshold) wrote Application event **1001** "disk.c FAILING", and the next
  normal run wrote **1000** "disk.c recovered".

**11. CRM live-lead observation (pending since M4) — completed.**
- **Window:** `observe-crm-live.mjs` ran 14:05–21:00 UTC, an unattended scheduled task over the production
  business window.
- **Mid-window check:** no lead by 18:30 UTC. The CRM engine state showed the clock in step with real time and
  exactly one lead in the queue for the day, at 20:48:48 UTC. Nothing was missing, and the dataset was not
  reset or touched.
- **Arrival:** company **501 "Keystone Logistics"** (industrials), `created_at` 20:48:48.199 UTC (planned business
  time), with 3 contacts, 1 intro note (warm) and 1 first task (a call due the next business day). No deal yet;
  per the model, a qualifying lead opens one 3–18 days later.
- **Audit:** 7 entries at 20:49:42 UTC (actor `simulator`, owner sales #6): company → contacts ×3 → note →
  contact update → task.
- **Live delivery:** the SSE `companies` insert reached the subscribed client at 20:49:42.139, 59 ms after the
  company row was written. 23 change events and 0 SSE errors over the window. The client is a Node SSE
  subscriber on the channel the UI uses; in-browser SSE rendering is covered by the public CRM E2E.

**12. Integration regression after today's changes.**
- CRM public E2E **10/10**; cleanup left 0 sign-in-capable test accounts.
- CRM production integrity **22 checks, 0 failing**.
- POS: integrity 43/43 (dependency promotion smoke); public visitor 4/4.
- Portal: CRM and POS status routes 200.
- Host Caddyfile SHA-256 unchanged throughout (`f606ec68…89b6`); Caddy reloaded, never restarted (process
  start 2026-11-09).
- Práctica reachable after every reload.

**Resources and latency** (`measure-resources.ps1`, 10 min, 30 requests per URL; CRM, Práctica, POS worker and
public POS all running):

Host:

| Measure | Value |
|---|---|
| CPU | average 18.1 %, p95 29.6 % |
| RAM | 9.3 / 12 GB used. The increase since the morning (6.8 GB) is interactive tooling on the host (editor ~3.3 GB, desktop AI clients), not hosted services |
| C: free | 14.2 GB |

Services:
- Caddy 39 MB / 0.2 % of one core.
- CRM: API 49 MB; PostgreSQL 27 MB / 0.1 %.
- POS: MariaDB 163 MB / 0.2 %; PHP workers 55 + 56 MB; simulation worker 113 MB / 0.6 %.
- Práctica: 31 + 59 MB / 0.2 %.
- All hosted services together: under 1.5 % of one core.

Disk (MB): POS app 97, MariaDB 307, POS backups 413 (4 dumps; 14-day retention, so steady state ≈ 1.5 GB),
PHP 88, CRM 175.

Latency:

| URL | median | p95 |
|---|---|---|
| POS public `/sign-in` | 336 ms | 397 ms |
| POS public `/harborpine/health` | 354 ms | 442 ms |
| Portal `/status/pos` | 363 ms | 461 ms |
| POS loopback health | 319 ms | 393 ms |
| CRM `/api/health` | 70 ms | 179 ms |
| CRM `/` | 56 ms | 107 ms |
| Portal `/healthz` | 55 ms | 90 ms |
| co-hosted application sign-in page | 62 ms | 110 ms |

All responses were 200. POS latency is PHP-CGI framework boot (Laravel + NexoPOS modules), the same over
loopback and public HTTPS.

## M9 — Release 1.0 final acceptance (2026-11-18, CRM + POS + portal)

Release-time verification. Everything here is non-disruptive except the portal text change (atomic swap with
graceful reload).

| Check | Method | Result |
|---|---|---|
| Public availability | `curl` of each URL | CRM `/` 200 and `/api/health` 200 `{"status":"ok"}`; POS `/sign-in` 200 and `/harborpine/health` 200 (`worker_running: true`, lag 1 s); portal `/`, `/status/crm`, `/status/pos` 200; co-hosted application 302 to its sign-in |
| Services | `Get-Service` | 7 portfolio services and Caddy running, automatic start; co-hosted services running |
| Scheduled tasks | `Get-ScheduledTaskInfo` | CRM backup, POS backup and health monitor: last result 0. The finished one-time CRM observation task was removed |
| Monitoring | monitor JSON log, Application log | every run all OK since installation; the only events are the deliberate failure/recovery test |
| CRM integrity | `node scripts/simulate.ts integrity` (production) | **22 checks, 0 failing**; simulation clock current (21:13 UTC), 185 queued events, 500 companies, 81 won deals ($2,070,500) |
| POS integrity | `php artisan hp:integrity --json` (production) | **43 checks, 0 failing**; 24,348 orders; paid sales $872,053.27 = dashboard; 26,793 ledger events |
| CRM backend suites | `node --test` (m4, poc, simulation) against `crm_test` | **42/42 pass**, 12 suites, 54 s |
| Backups | `C:\srv\portfolio\backups` | CRM 7 files, latest 03:15 (1.3 MB); POS 4 dumps, latest 10:30 (103.4 MB); all with `.sha256`; next nightly runs 03:15 / 03:45 |
| Portal accuracy | content review | hero corrected: it claimed "three business systems that are actually running" while the ERP is not. Now: CRM and POS running, ERP in preparation; meta description and footer (Release 1.0) updated. Credits name upstream authors and licences |
| Portal deploy | `deploy-portal.ps1` | validate + graceful reload; smoke tests pass; host Caddyfile SHA-256 unchanged; Caddy process start unchanged (2026-11-09) |
| Portal browser check | Chromium, 1366 px and 390 px | 0 page, console or request errors; no horizontal scroll; status `crm: operational`, `pos: operational · simulation live`, `erp: in preparation`; CRM/POS buttons link to the public hosts; screenshots loaded |
| Repository hygiene | scan of tracked files | no IP addresses, no owner e-mail, no secrets. Webmail-style addresses appear only in the upstream Atomic CRM snapshot's own faker test fixtures, and fixed passwords only in tests against the throwaway test database |
| Documentation accuracy | review | ARCHITECTURE claimed a NexoPOS `schedule:run` task that does not exist; corrected, and recorded as limitation L21. Licence boundary paths, R-003/R-009/R-010 statuses and README status updated |

Delivery package: FINAL_DELIVERY, ACCEPTANCE_MATRIX, OPERATIONS_HANDBOOK, RECOVERY_GUIDE, KNOWN_LIMITATIONS
(D-018).

## M5 — ERP custom app, repository level (2026-11-18, no ERPNext runtime)

Nothing here ran against ERPNext. Release 1.0 (CRM, POS, portal) and the co-hosted application were not
touched. No WSL, runtime component or reboot.

**Pinned sources:**
- `git clone --depth 1 --branch v16.60.0` of erpnext (`886ab6a`) and frappe (`bf9581a`); both `__version__` =
  16.60.0. They live in the git-ignored `upstream/`.
- The earlier ERPNext clone was on `develop` (v17-dev) and was not used for verification.

**Engine and static tests** (`python -m unittest discover -s apps/erp/tests`, Python 3.13 on the host; the engine
has no Frappe imports): **35/35 pass** (about 18 s).

| Area | What is asserted |
|---|---|
| RNG | same seed, same stream; pinned values; uniform/Poisson means; weighted choice |
| Calendar | 2025/26 holidays incl. observed July 4th and the day after Thanksgiving; business-day arithmetic; month due days |
| Catalogue | 450–650 curated values (497); 96 unique items; every group has a supplier; no placeholders or e-mail/URLs; independent of the CRM/POS scenarios; terms and expense accounts resolve |
| Scenario | deterministic per seed; 150 unique customers; list price > cost; SKU format; warehouse by territory; tax only for Ohio non-exempt customers; account managers from staff |
| Planner | identical hash on rerun and equal to a persisted day-by-day run with fresh processes (recovery); re-planning a day refused; unique keys in time order; business days only; references point to earlier events of the right kind; chain dates (invoice = delivery day, bill after receipt, returns ≥ 3 days later, payments after invoice); delivered/received/returned ≤ ordered/delivered; fully received purchase orders closed; stock replay never negative and equal to the projection; 10–20 orders per business day with December below October; first delivery complete for > 75 % of orders; returns 2–10 % of invoices; every invoice paid, scheduled (late payer) or fully credited; purchase lines in pack sizes at cost ±10 %; weekly and month-end routines on the right days; pinned first-month hash |
| Static | every app module compiles; the engine imports no Frappe/ERPNext; the app matches the pinned sources; **self-tests**: the checker reports an unknown field, an unknown child-table field, an invalid Select value, a wrong or missing function signature and an unknown account |

**Static verification against the pinned sources** (`python scripts/verification/check_erp_upstream.py`):
- **868 DocTypes indexed, 675 checks passed, 0 problems.**
- Coverage: pinned versions; 13 function signatures (mappers, `get_payment_entry`, `setup_complete`,
  `get_stock_balance`, `get_root_of`, `filelock`); controller methods (Payment Reconciliation, Document); every
  field, child-table field and Select value the services write or read; integrity SQL columns; Standard chart
  accounts; fixture UOMs, modes of payment and price lists; app DocTypes and hooks.
- **First run found 1 real defect:** v16's Item Group has no `description` field. The group descriptions are now
  stored as comments.

**Full plan statistics** (seed 20261119, 2025-08-01 → 2026-11-18): 26,461 events in 11 s; 5,094 sales orders
(15.4 per business day), 6,266 deliveries and invoices, 5,347 customer payments, 567 purchase orders, 311 returns
(5.0 %), 390 reconciliations, 1,114–2,054 events per month.

**Written, not yet executed:**
- `portfolio_sim/tests/test_lifecycle.py` (7 ERPNext integration tests);
- the 32 integrity checks and the replay check on a real site;
- browser E2E (not written yet).

Execution needs the WSL1 runtime ([ERP_WSL1_POC.md](runbooks/ERP_WSL1_POC.md), owner decision REBOOT).
(Superseded for the Linux runtime by the next section.)

## M5 — ERPNext integration on Linux (GitHub Actions, 2026-11-18/19)

**Scope:** this validates the **application on real Frappe/ERPNext v16.60.0 on Linux**. It does **not** validate WSL1
on the Windows host, which is untested. Release 1.0, the co-hosted application and the VPS were not touched: the
runner is a temporary GitHub-hosted machine with throwaway credentials.

**Workflow** (`.github/workflows/erp-integration.yml`, manual trigger):
- runner: ubuntu-24.04 (4 vCPU), `setup-python` 3.14.10, Node 24;
- services: MariaDB 11.8 service container (utf8mb4 settings as in ERPNext's CI), `redis-server` from apt;
- bench: `bench init --frappe-branch v16.60.0`, `bench get-app erpnext --branch v16.60.0`, the app from this
  repository, a new `test_site` with ERPNext and `portfolio_sim`;
- tests: `run-tests --module portfolio_sim.tests.test_lifecycle`, then integrity, replay and ledger/GL summaries
  uploaded as evidence;
- guards: the JUnit report must show exactly 7 tests with no failures, errors or skips; the history must have at least
  1,000 executed events with ledger rows = executed count; integrity and replay must exit 0.

**Run history (every failure and fix):**

| Run | Result | Finding | Fix |
|---|---|---|---|
| 44410189095 | failed at app install | flit: `pyproject.toml` named a `README.md` that did not exist in the app directory | app README added |
| 44411077780 | **false pass** | `run-tests --skip-test-records` returns **without running anything** in Frappe v16 (exit 0); integrity "passed" on an empty, un-initialised site | flag removed; JUnit and minimum-history guards; `integrity`/`replay-check` refuse an un-initialised simulation |
| 44411918611 | setup error | `Could not find Gender: Female`: ERPNext's programmatic setup does not create Gender records (Frappe's interactive wizard does) | setup creates them; `unittest-xml-reporting` installed |
| 44412742127 | 2/7 | Stock Reconciliation with more than 100 rows is **queued as a background job** instead of submitted. The 280-row opening stock stayed a draft and every delivery hit NegativeStockError | opening stock per warehouse (≤ 96 rows, engine test); `submit` helper raises unless docstatus = 1 |
| 44414165205 | 2/7 | `Due Date cannot be after …`: mappers compute due dates from today. Also the `bin_vs_stock_ledger` check was wrong (reconciliation entries carry `actual_qty` 0) | explicit due dates from party terms; check compares Bin with the latest entry's `qty_after_transaction` |
| 44414979203 | 5/7 | the two failing count assertions were wrong expectations (first receipt planned 18 Aug, first supplier payment 11 Sep) | tests now require document counts **exactly equal to the deterministic plan** |
| 44417258442 | 6/7 | **every order was priced at 0**: server-side, ERPNext fills item fields only when they are `None`, and new rows default to 0, so the Standard Selling price was never fetched. 93/93 payments were "Nothing Due" and there was no Sales Invoice GL. A weak pricing assertion (0 = 0) passed | `price_list_rate` passed, ERPNext computes the discounted rate; 4 new zero-value integrity checks; pricing test requires positive rates = Item Price − discount; ≥ 90 % of payments must post |
| 44419501627, 44421664339 | 4/7 | (1) 2 system journals reconciling credit notes were dated on the runner's current day: their date comes from the allocation's `debit_or_credit_note_posting_date`, else `today()`. (2) All 26 payment-before-invoice rows were customer **advances** allocated to later invoices (legitimate) | allocation date set to the reconciliation day; advances excluded from that chronology check (rows recorded as evidence first) |
| **44423743980** | **7/7** | 1,816 events (to 2025-09-12); 36 integrity checks at 0; replay exact | window extended to cover purchase returns |
| **44425817273** | **7/7 (current)** | see below | — |

**Run 44425817273** (commit `72fd3c4`, about 17 min):
- **Tests:** JUnit 7/7, with no failures, errors or skips.

| Test | Time |
|---|---|
| test_01 master data | 0.05 s |
| test_02 opening day | 5.3 s |
| test_03 two weeks | 117 s |
| test_04 five weeks | 251 s |
| test_05 replay | 0.2 s |
| test_06 rerun, no duplicates | 0.01 s |
| test_07 crash and recovery to 2025-10-03 | 413 s |

- **History:** 3,068 events over 64 business days, from 2025-08-01 to 2025-10-03. Ledger rows = executed = 3,068.
- **Integrity: 36 checks, all 0.** The general ledger is balanced per voucher and in total. AR and AP agree with the
  payment ledger. Bin agrees with the stock ledger, and stock value with the Stock accounts. Document
  relationships, chronology and ledger coverage hold, with no zero-value lines or invoices and nothing dated after
  the processed point.
- **Replay:** 3,068 planned = 3,068 recorded; missing, unexpected and mismatched all 0; the planner state matches.
- **Documents** (each equal to the plan, asserted):

| Document | Count |
|---|---|
| Sales Orders | 709 |
| Delivery Notes | 911 (865 deliveries, 46 returns) |
| Sales Invoices | 911 (865 invoices, 46 credit notes) |
| Purchase Orders | 66 |
| Purchase Receipts | 49 (48 receipts, 1 return) |
| Purchase Invoices | 41 (40 bills, 1 debit note) |
| Payment Entries | 306 (288 customer payments, 15 advances, 3 supplier payments) |
| Stock Entries | 26 |
| Stock Reconciliations | 5 (3 opening, 2 cycle counts) |
| Journal Entries | 33 |

  Reconciliation: 37 allocating, 15 with nothing to allocate.
- **Business behaviour verified on real ERPNext:**
  - every sales line at the Standard Selling price less the customer discount;
  - partial deliveries (orders with more than one delivery);
  - credit notes and returns into the Returns warehouse, plus a purchase return and debit note;
  - reconciliation of advances and credit notes;
  - Ohio tax on taxable customers;
  - opening stock at cost, cleared to equity;
  - stock valuation consistent with the GL.
- **Exactly-once on real ERPNext:**
  - a re-run of the processed window adds no ledger rows and no GL entries;
  - an injected crash after documents were created rolls back completely, and the next run executes the event once
    (documents equal the plan).
- **GL by voucher type** (debit = credit):

| Voucher type | Vouchers | Debit = credit (USD) |
|---|---|---|
| Sales Invoice | 911 | 401,515.20 |
| Delivery Note | 911 | 309,467.98 |
| Payment Entry | 306 | 312,655.53 |
| Purchase Receipt | 49 | 199,181.49 |
| Purchase Invoice | 41 | 157,640.44 |
| Journal Entry | 33 | 2,144,104.98 |
| Stock Reconciliation | 5 | 309,035.72 |

- **Throughput:** about 3.9 events/s on the 4-vCPU runner.

**Not covered yet:**
- Month-end settlement of advance payers was always "Nothing Due" in this window: their advances covered every
  invoice. The payment path it uses is the same as customer payments, which is exercised 288 times.
- Browser E2E (not written).
- WSL1 compatibility (untested).

## M5 — pre-reboot readiness (2026-11-18, no change to Windows)

No feature was enabled, no service or configuration changed, and there was no reboot.

**`preflight-reboot.ps1 -RunBackups`** (17:16 local): **0 failing**. 33 checks pass; 2 are owner confirmations.

| Area | Result |
|---|---|
| Services | Caddy, 7 portfolio services, the co-hosted application's 2 services, sshd, RustDesk, AnyDesk, Jump Desktop and Task Scheduler: Automatic and Running. Remote Desktop enabled |
| Features | WSL, VirtualMachinePlatform, Hyper-V and HypervisorPlatform: Disabled |
| Pending reboot | no servicing or Windows Update reboot. Queued file operations: 116 print-spooler driver-cache deletions, 3 Chrome installer leftovers, 1 Edge log rotation (no system files) |
| Fresh backups | CRM `crm-20261118-171611.dump` (1.3 MB): restore check OK, row counts equal. POS `pos-20261118-171621.sql` (103.6 MB): restore check OK, counts and text checksums equal |
| Nightly tasks | CRM backup, POS backup and the co-hosted daily backup: last result 0 (within 26 h) |
| Monitor | 10/10 OK |
| Git | working tree clean; HEAD = origin/main |
| Owner confirmations | provider out-of-band console; maintenance window and REBOOT approval |

**`post-reboot-check.ps1 -ExpectWsl Disabled`** (trial in the current state, before any reboot): **25/25 pass**.
- All Release 1.0, co-hosted and remote-access services Running; monitor OK.
- POS: simulation lag 15 s, integrity 43/43, no duplicate ledger keys. CRM integrity 22/22.
- Co-hosted application HTTP 302; Caddyfile hash unchanged; VirtualMachinePlatform, Hyper-V and HypervisorPlatform Disabled.

**`set-db-service-recovery.ps1`** (dry run): the CRM PostgreSQL and POS MariaDB services have no failure actions. The
proposed restart after 10/30/60 s is **not applied**; that needs owner authorisation.

