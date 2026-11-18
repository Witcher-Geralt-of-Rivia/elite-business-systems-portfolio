# Architecture

> Status: **initial draft (M0)**. Sections marked _TBD (Mx)_ are filled in when that milestone produces evidence.

## 1. System context

```text
                Internet
                   │  HTTPS (sslip.io hostnames)
                   ▼
        ┌─────────────────────────┐
        │ Reverse proxy (Caddy)   │  per-host TLS, HTTP→HTTPS, WS/SSE
        └──┬──────┬──────┬──────┬─┘
           │      │      │      │
       portal    crm    erp    pos          (each an independent stack)
           │      │      │      │
           │   Postgres MariaDB MySQL/MariaDB   (private, never exposed)
           │      │      │      │
           │   CRM sim ERP sim POS sim          (server-side workers)
```

Each application is an independent product with its own database, data engine, scheduler, backups, and tests. Shared code is limited to generic tooling (seeded RNG helpers, distribution utilities, verification scripts) — never business schema.

## 2. Upstream integration strategy

Upstream code is referenced at pinned revisions, not vendored:

| App | Mechanism | Customization surface |
|---|---|---|
| CRM | Pinned upstream revision built from source | Atomic CRM `<CRM>` customization props, Supabase migrations, edge/SQL functions |
| ERP | Custom Frappe app (`portfolio_sim`) installed alongside pinned ERPNext | DocType hooks, scheduler events, fixtures, whitelisted APIs |
| POS | NexoPOS module | Module service providers, events, artisan commands, migrations |

Pinned revisions (D-005): ERPNext/Frappe v16.60.0, NexoPOS v6.3.0, Atomic CRM `main@22f38f0f`. Extension points, schemas and simulator APIs with source references: [UPSTREAM_AUDIT.md](UPSTREAM_AUDIT.md).

## 3. Host runtime

Known facts (inspected 2026-11-17, read-only):

- Host: Windows Server 2025 Standard (build 26100), itself a VM under a hypervisor.
- 2 cores / 3 logical CPUs, 12 GB RAM (~6 GB free at inspection), ~18 GB free disk on the system drive.
- No WSL installed; no Docker installed. **Confirmed: virtualization extensions are not exposed to the guest** → WSL2/Hyper-V/Docker Linux containers are impossible (R-001).
- An existing Caddy service already terminates HTTP/HTTPS for other workloads on this host, with working sslip.io certificates; it must be extended, not replaced.

Since 2026-11-17 the VPS was dedicated to this portfolio (D-008); since 2026-11-18 it again also hosts one
unrelated application of the owner (D-016), served by the same host Caddy under its own hostname. Runtime per app (D-009 supersedes D-007's CRM row):

| App | Runtime | DB |
|---|---|---|
| POS | Native Windows: PHP 8.3 (NTS) via Caddy `php_fastcgi` → php-cgi, Task Scheduler for `schedule:run` | MariaDB 11.8 (native, loopback) |
| CRM | Atomic CRM SPA (static, served by Caddy) + **own Fastify API** (Node 24, Windows service) + in-process simulation worker. **No Supabase.** | Dedicated PostgreSQL 16 cluster `portfolio-crm-postgres` (loopback, D-010), restricted role |
| ERP | WSL1 Ubuntu: Frappe bench v16 (gunicorn, socketio, RQ workers, scheduler) — **PoC-gated, reboot needs separate approval** | MariaDB 11.8 (native, loopback) + Redis-compatible server |

### CRM backend (D-009)

```text
browser ──HTTPS──► Caddy ──► crm.<ip>.sslip.io
                             ├─ /            static Atomic CRM build
                             └─ /api/*  ──►  Fastify API (127.0.0.1)
                                              ├─ auth: opaque sessions (httpOnly cookie), scrypt, lockout, CSRF
                                              ├─ team: invitations + one-time password links (no email)
                                              ├─ REST resources (react-admin conventions)
                                              ├─ RBAC + record-level rules (server-enforced)
                                              ├─ global search (ported global_search(): tsvector + unaccent)
                                              ├─ contact merge (single transaction)
                                              ├─ attachments → C:\srv\portfolio\crm\files (+ metadata rows)
                                              ├─ SSE /api/events (LISTEN/NOTIFY fan-out)
                                              └─ pg pool ──► PostgreSQL 16 (db: crm, role: crm_app)
                         simulation worker (in-process, CRM_SIMULATION=live)
                           └─ writes through the same ResourceService (validated, audited)
```

The browser never talks to PostgreSQL. Migration inventory: [CRM_SUPABASE_MIGRATION.md](CRM_SUPABASE_MIGRATION.md).

## 4. Data engines

- **CRM:** [CRM_DATA_ENGINE.md](CRM_DATA_ENGINE.md) — event-driven B2B sales model, ~500 curated values, deterministic reset/replay, live worker, 21 integrity checks.
- ERP, POS: _TBD (M5–M6)_.

## 5. Security model

Showcase visitor access model, secrets management, network exposure: _TBD (M3/M8)_.
