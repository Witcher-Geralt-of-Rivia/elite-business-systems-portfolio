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

Exact revisions, extension points, and schema notes: _TBD (M1)_.

## 3. Host runtime

Known facts (inspected 2026-11-17, read-only):

- Host: Windows Server 2025 Standard (build 26100), itself a VM under a hypervisor.
- 2 cores / 3 logical CPUs, 12 GB RAM (~6 GB free at inspection), ~18 GB free disk on the system drive.
- No WSL installed; no Docker installed. Processor reports virtualization extensions **not** exposed to the guest → WSL2/Hyper-V/Docker Linux containers are likely unavailable (to be confirmed in M2).
- An existing Caddy service already terminates HTTP/HTTPS for other workloads on this host; it must be extended, not replaced.

Runtime choice per app: _TBD (M2)_ — see `docs/RISKS.md` R-001..R-003.

## 4. Data engines

Per-app engine design (source-value libraries, distributions, state machines, live scheduler, idempotency keys, event log): _TBD (M4–M6)_.

## 5. Security model

Showcase visitor access model, secrets management, network exposure: _TBD (M3/M8)_.
