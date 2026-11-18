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
