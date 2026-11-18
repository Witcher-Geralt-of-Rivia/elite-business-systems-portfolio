# Decision Log

Format: ID · date · decision · alternatives rejected · status.

## D-001 · 2026-11-17 · Single public portfolio repo; upstreams referenced, not vendored
- Upstream code is pinned by revision (submodule or scripted checkout into git-ignored `upstream/`), customizations live in this repo.
- Rejected: copying three full upstream histories in (bloats repo, obscures what is original work, complicates license boundaries).
- Status: accepted.

## D-002 · 2026-11-17 · Repo-local git identity uses GitHub no-reply email
- Commits use `<id>+<login>@users.noreply.github.com` so the owner's personal email never enters public history.
- Status: accepted.

## D-003 · 2026-11-17 · Licensing structure
- Original, separable portfolio components (portal, generic tooling, infra scripts, CRM customizations): MIT (root `LICENSE`).
- ERPNext and NexoPOS extensions (Frappe app, NexoPOS module): GPL-3.0, each with its own `LICENSE` file in its directory, because they link against GPL code.
- Rejected: a single MIT license for everything (would misstate obligations for GPL derivatives).
- Status: accepted; owner may choose a different license for original components.

## D-004 · 2026-11-17 · Host-identifying details stay out of the public repo
- Public IP, port/service inventory, and VPS usernames are not committed. Configuration takes `PUBLIC_IP` from the environment; docs use `<VPS_IP>`.
- Note: the deployed sslip.io hostnames necessarily embed the IP once the portal is live; that is an accepted, deliberate exposure at deployment time, not in source.
- Status: accepted.

## D-005 · 2026-11-17 · Upstream pins
- ERPNext **v16.60.0** + Frappe **v16.60.0** (stable `version-16`), NexoPOS **v6.3.0**, Atomic CRM `main@22f38f0f` (CHANGELOG v1.6.0).
- Rejected: ERPNext `develop` (v17-dev, moved mapper modules, unstable); ERPNext v15 (older; v16 is current stable with active patch releases).
- Status: accepted.

## D-006 · 2026-11-17 · Data generation through application services only
- CRM: supabase-js as real authenticated users (PostgREST + RLS). ERP: custom Frappe app using document lifecycle + ERPNext mappers, chronological backfill with `set_posting_time`. POS: NexoPOS module calling `OrdersService`, `ProcurementService`, `CashRegistersService` with a controlled clock, then report recompute.
- Rejected: direct SQL seeding (bypasses validation, breaks ledgers/aggregates — violates X-DB-2).
- Status: accepted.

## D-007 · 2026-11-17 · Host runtime strategy (proposed — awaiting owner approval)
- No nested virtualization (R-001) rules out Docker/WSL2. Proposed: POS fully native Windows (PHP + MariaDB); CRM as a self-hosted Supabase subset (Postgres, PostgREST, GoTrue, Storage, Deno) behind Caddy; ERP via WSL1 for Python/Node processes with native MariaDB + Redis-compatible server, gated by a time-boxed PoC.
- Rejected: Docker Desktop on Windows Server (unsupported, and needs virtualization anyway); reinstalling/migrating the VPS (prohibited without permission); Supabase cloud (external service; fallback only).
- Status: **superseded by D-008 and D-009** (2026-11-17, owner decision). Retained for history.

## D-008 · 2026-11-17 · Host consolidation (owner decision)
- The owner authorized retiring four unrelated websites hosted on the VPS. Their Caddy routes were removed (graceful `caddy reload`), their dedicated Windows services stopped and set to **Disabled**. Nothing was deleted: project files, databases, and their dedicated PostgreSQL service are untouched; dated backups and a restore script exist on the host (not in this repo).
- The host Caddyfile now holds only the original global options plus `import C:/srv/portfolio/caddy/*.caddy` (see `infrastructure/proxy/Caddyfile.host.example`).
- Caddy runs as the virtual account `NT SERVICE\caddy`; portfolio directories grant it least privilege (RX on site config + web root, Modify on logs only).
- Not stopped (out of scope / owner's tooling): PostgreSQL services, remote-access tools, unrelated loopback-only dev processes, an `nginx` service not tied to the retired sites.
- Status: **done**, verified (TEST_RESULTS §Consolidation).

## D-009 · 2026-11-17 · CRM without Supabase (owner decision; supersedes D-007 CRM row)
- Atomic CRM frontend (React/TS) is kept. Supabase (cloud and self-hosted) is removed entirely.
- New backend: native-Windows Node.js service (**Fastify**), PostgreSQL 16 via a restricted role, REST API consumed through a custom react-admin `DataProvider` + `AuthProvider`, application-managed sessions (httpOnly cookies, argon2id/scrypt hashing), server-enforced RBAC and record-level rules, local attachment storage with metadata in Postgres, SSE for live activity, dedicated Node simulation worker.
- Fastify over NestJS: smaller footprint on a RAM-constrained host, first-class JSON-schema validation, fewer abstractions to maintain for a ~30-endpoint API.
- PostgreSQL: isolated database + restricted role inside the **existing** PostgreSQL 16 cluster (saves ~100–150 MB vs. a second cluster), provided this can be done without altering other databases.
- Gate: proof of concept (auth, one full CRUD workflow, persistence) before full migration. If disproportionate, present a source-backed alternative CRM before changing the foundation.
- Status: **accepted; PoC in progress**.

## D-010 · 2026-11-17 · Dedicated PostgreSQL cluster for the CRM (deviation from owner preference, justified)
- The owner preferred a database + restricted role inside the existing PostgreSQL 16 installation. That cluster enforces `scram-sha-256` for every connection and its superuser password is not available to the agent. The only ways in would be (a) temporarily switching its `pg_hba.conf` to `trust`, which would expose the owner's unrelated databases to any local process during the window, or (b) asking the owner for the superuser password.
- Chosen: a separate cluster from the **same PG16 binaries** (no new installation): service `portfolio-crm-postgres`, `127.0.0.1:5433`, data under `C:\srv\portfolio\crm\pgdata`, runs as NetworkService, `shared_buffers=64MB`, `max_connections=30`. Measured cost: ~50–80 MB RAM idle, ~45 MB disk empty.
- Benefits: the CRM can be reset/restored without touching other data; credentials are fully owned by this project.
- Reversible: if the owner later provides the main cluster's superuser password, `pg_dump`/`pg_restore` into it takes minutes and the dedicated service can be removed.
- Roles: `crm_owner` (NOLOGIN, owns schema), `crm_app` (LOGIN, DML only, used by API + simulator), `crm_superuser` (cluster admin, used only for bootstrap/migrations). Databases `crm` and `crm_test`.
- Status: accepted.

## D-011 · 2026-11-17 · CRM PoC gate passed — proceed with full Supabase removal
- Evidence: 15/15 API tests and 2/2 browser tests against the live HTTPS deployment (TEST_RESULTS §CRM PoC). Upstream UI ran unchanged except for the provider swap (2 import lines) and new provider files; the upstream FakeRest demo provider compiled without edits.
- Inventory size (CRM_SUPABASE_MIGRATION.md) is proportionate (~32 endpoints), so no alternative CRM is proposed.
- Remaining Supabase-coupled features scheduled for M4: first-run sign-up, team-member management/invitations, password change/reset, global search (port of `global_search` SQL), contact merge, attachments (local storage), SSE live updates, removal of `@supabase/*` / `ra-supabase-core` dependencies and of the MCP/SSO UI.
- Status: accepted.

## D-012 · 2026-11-17 · Pause new deployment on the VPS after confirmed malware (security blocker)
- Investigation (docs/SECURITY_INVESTIGATION.md) confirmed an executed information-stealer loader from 2026-10-07 with full admin rights. No current activity observed, but the second stage is unknown.
- Per the owner directive ("never bypass a security blocker"), the agent pauses: new deployments, creation of new secrets on the host, and CRM M4 development work that would run on it. Existing services (portal placeholder, empty CRM) remain up; they hold no real data.
- Evidence left untouched (task disabled, payload in place) for the owner's decision. No containment action that deletes or moves evidence was taken.
- Recommended path: owner rotates credentials from a trusted device, then rebuilds the VPS from a clean image and the agent redeploys from GitHub. Alternative: in-place remediation with documented residual risk.
- Status: **active blocker** until the owner decides.

## D-013 — Resume development without a host rebuild (2026-11-17, owner)

- **Decision (owner):** the VPS is **not** rebuilt. Development resumes: CRM M4 features and the CRM data engine first, then
  POS (M6) preparation and non-disruptive ERP (M5) research. GitHubRepoManager.exe is the owner's own software (F11 closed).
- **Constraints kept:** no new secrets and no expansion of public deployment on this host without separate authorization;
  WSL1 reboot still unapproved; the security incident stays open in RISKS (R-014) — it is not declared resolved.
- **Supersedes:** the development pause in D-012 (D-012's deployment/secret restrictions continue as stated above).


## D-014 — CRM visitor access: credential-free, read-only showcase sessions (2026-11-17)

- **Decision:** visitors click "Explore the live demo" and get a 2-hour session for a dedicated `showcase`
  account **that has no password** (nothing to publish or leak; it cannot sign in with credentials and no
  password link can be issued for it). Enabled by `CRM_SHOWCASE=on`.
- **Enforcement:** showcase sessions are read-only at the HTTP layer (every state-changing request except
  logout, and every private-file download, returns 403 `showcase_read_only`), and again in the service layer
  (`write.showcase = none`). The UI does not hide every edit control: ra-core's embedded create/edit
  controllers turn a UI-level denial into "Access denied" pages, so instead a permanent banner states the
  mode and refused saves show "This is a read-only demo: changes are disabled."
- **Presentation:** `/api/auth/me` presents visitors as "Guest · viewing as <busiest active rep>" so personal
  widgets (hot contacts, upcoming tasks) show real work. Only the identity shown changes; the session stays the
  showcase account. Never an administrator.
- **Unchanged:** first-user sign-up stays closed once a real user exists (the showcase account is ignored
  for that check); no public registration.

## D-015 — POS native runtime (2026-11-17)

- PHP 8.3.36 NTS x64 (official build, SHA-256 verified) under `C:\srv\portfolio\pos\php`, served to Caddy via
  `php-cgi` FastCGI workers (Windows php-cgi handles one request at a time, so several workers sit behind
  Caddy's `php_fastcgi` load balancing).
- MariaDB 11.8.10 (official zip, SHA-256 verified) as its **own** service `portfolio-pos-mariadb`
  (NETWORK SERVICE, `127.0.0.1:3307` only, 128 MB buffer pool), database `nexopos`, account `nexopos_app`
  limited to that database. Kept separate from the ERP's future MariaDB (X-DB-1); sharing one server
  process is a later, measured option (R-005).
- NexoPOS v6.3.0 (tag commit `1e9b2e2`) exported from upstream into `C:\srv\portfolio\pos\app`; portfolio code
  is a NexoPOS **module** (GPL-3.0) in `apps/pos/`, never a core patch.

## D-016 — Shared hosting: owner's Práctica application restored (2026-11-18, owner authorization)

- **Context:** the owner explicitly authorized reactivating *Práctica* (their own Django application, retired
  from this host in the D-008 consolidation) alongside the portfolio. It is not part of this repository:
  its source, configuration and secrets stay outside it.
- **State verified on 2026-11-18:** the web service was back on automatic start and running, and its own
  PostgreSQL service was running. The host Caddyfile carried only Práctica's original site block, restored from
  the consolidation backup, with a pre-change backup kept. The running Caddy config served the portfolio and
  Práctica hostnames together after a graceful reload. Both Práctica services listen on loopback only.
- **Verified:** `manage.py check` 0 issues, no planned migrations, and a database connection; nothing was
  migrated, reset or deleted. Public HTTPS is served with a trusted certificate, HTTP→HTTPS redirect and
  HSTS. The sign-in page loads, the CSRF-protected login POST is accepted and wrong credentials are refused with
  the application's message, static assets are served, and admin pages require sign-in. CRM public health and
  UI returned 200; the POS stays non-public. The POS backfill kept progressing without interruption. Práctica
  uses about 220 MB RAM and negligible CPU.
- **Consequences for the portfolio:** the host is shared again (D-008 is superseded on this point).
  Portfolio changes touch only the imported portfolio site files and always validate the complete host
  Caddyfile before a graceful `caddy reload`, never a service restart. Portfolio services must not use
  Práctica's local ports, which are documented on the host, not here.

## D-017 — POS public release (2026-11-18, owner authorization POS-PUBLIC)

- **Decision:** the owner approved public HTTPS access to the Harbor & Pine Market NexoPOS at
  `https://pos.<VPS_IP>.sslip.io`, through the guarded procedure `activate-pos-public.ps1 -OwnerApproved`.
- **Conditions kept:**
  - visitors get read-only showcase sessions only;
  - registration stays disabled;
  - administrator credentials are not published;
  - destructive tests keep running only on isolated database copies;
  - the shared Caddy service is reloaded, never restarted;
  - the host Caddyfile, CRM and Práctica are not modified.
- **Rollback:** `activate-pos-public.ps1 -Rollback` removes the host-side approval flag, re-renders the loopback-only
  site with a graceful reload, and switches the portal back to "being finalised".
- **Not implied:** public activation does not establish that the VPS has been remediated. The historical
  incident (R-014, D-012/D-013) stays open. Credential rotation and host remediation remain owner actions
  (SEC-ROTATE).
- **Unchanged:** ERPNext stays on hold, with no WSL installation and no reboot without separate approval.

