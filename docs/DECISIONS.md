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
- Status: **proposed**.
