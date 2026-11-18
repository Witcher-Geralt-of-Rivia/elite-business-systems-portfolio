# Progress Log

Newest first. Every entry states what was **verified**, not just what was written.

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
