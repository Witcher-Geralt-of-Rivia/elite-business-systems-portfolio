# Deployment

> Status: **not yet deployable.** The deployment method is decided in M2 (see `docs/RISKS.md` R-001..R-006). This file will become the step-by-step runbook.

## Target hostnames (sslip.io, no domain purchase)

```text
https://portfolio.<VPS_IP>.sslip.io
https://crm.<VPS_IP>.sslip.io
https://erp.<VPS_IP>.sslip.io
https://pos.<VPS_IP>.sslip.io
```

`<VPS_IP>` is supplied at deploy time via the `PUBLIC_IP` environment variable; it is not committed.

## Operating constraints

- The host already runs a Caddy reverse proxy for unrelated sites. Portfolio routes are added as separate, imported site blocks; the existing configuration is backed up first and validated before reload.
- Databases bind to loopback only. No database or admin port is exposed publicly.
- Remote access (RDP/SSH) and firewall rules are never altered in ways that could lock out the owner.

## Runbook

### Reverse proxy (done 2026-11-17)

1. Host Caddyfile (`C:\srv\caddy\Caddyfile`) = original global options + `import C:/srv/portfolio/caddy/*.caddy` (shape: `infrastructure/proxy/Caddyfile.host.example`).
2. Site templates live in `infrastructure/proxy/sites/*.caddy.tmpl`. Render and hot-reload:
   ```powershell
   $env:PUBLIC_IP = '<VPS_IP>'
   .\scripts\provisioning\render-caddy-sites.ps1      # validates; restores previous files on failure; graceful reload
   ```
3. Caddy runs as `NT SERVICE\caddy`. Each new portfolio directory it must read needs an explicit grant (the parent `C:\srv` is locked down):
   ```powershell
   icacls C:\srv\portfolio\<dir> /grant "NT SERVICE\caddy:(OI)(CI)(RX)"   # read-only content
   icacls C:\srv\portfolio\logs  /grant "NT SERVICE\caddy:(OI)(CI)(M)"    # logs only
   ```
   Symptom when missing: `caddy reload` → HTTP 400 "mkdir … Cannot create a file when that file already exists"; the running config stays unchanged.

### Runtime layout on the host

```text
C:\srv\portfolio\
  caddy\        rendered site files (imported by host Caddyfile)
  portal\www\   portal static build
  logs\         access/app logs (rotated)
  backups\      per-app DB backups (never committed)
```

Application runbooks: _TBD (M4–M6)._

## Backup & restore

Nightly scheduled tasks run as SYSTEM with 14-day retention. Each dump gets a `.sha256` file and is restored into a
scratch database on every run (`-VerifyRestore`); the scratch database is then dropped.

| Task | Time | What | Restore check |
|---|---|---|---|
| Portfolio - CRM nightly backup (`backup-crm.ps1`) | 03:15 | `pg_dump` custom format → `C:\srv\portfolio\backups\crm\crm-<stamp>.dump` (≈1.3 MB) | row counts of the business tables |
| Portfolio - POS nightly backup (`backup-pos.ps1`) | 03:45 | `mariadb-dump --single-transaction` (no locking of the live store) → `C:\srv\portfolio\backups\pos\pos-<stamp>.sql` (≈103 MB) | row counts and text-column checksums (catches encoding damage) |

- **Storage:** CRM about 20 MB and POS about 1.5 GB at steady state, both on C:. The monitor alarms below 3 GB
  free.
- **Credentials:** read from `C:\srv\portfolio\secrets` (Administrators/SYSTEM only); passwords are passed
  through the environment, never on the command line.
- **Logs:** `C:\srv\portfolio\logs\maintenance\backup-*-<date>.log`.
- **Off-host copies:** none yet. The backups protect against application or data errors, not loss of the
  VPS (see RISKS).
- **Ad-hoc backup:** run the script with `-VerifyRestore`. `activate-pos-public.ps1` does this before every
  activation.

## Recovery

Before any database repair, take a verified backup and rehearse on a clone. Repairs go through the
application's own services (`hp:repair-refunds`, for example), never raw edits.

| Situation | Action |
|---|---|
| A service stops | WinSW restarts the CRM API, the POS PHP workers and the POS simulation worker on exit. The worker exits with code 3 to recycle and restarts after 30–60 s. The monitor logs the state change |
| POS simulation behind or interrupted | Restart `portfolio-pos-sim`. It catches up from its watermark, and the idempotency ledger prevents duplicates (verified for pause, service restart and a mid-day kill) |
| POS must leave the internet | `activate-pos-public.ps1 -Rollback` removes the approval flag, re-renders with a graceful reload, and switches the portal POS card back to "being finalised" |
| Bad Caddy site render | `render-caddy-sites.ps1` validates the whole host Caddyfile before reloading and restores the previous site files if validation fails. The Caddy service is never restarted |
| Bad portal deploy | `deploy-portal.ps1` restores the previous `www` copy automatically when its smoke tests fail; the last 3 copies are kept |
| Data loss or corruption | Restore the newest verified dump into a scratch database, compare, then swap in during a maintenance window. Only the scratch restore is exercised nightly; a production-level restore has not been rehearsed |

## POS dependency updates

NexoPOS is pinned at v6.3.0. Its PHP dependencies get security updates inside upstream's own version constraints,
using `scripts/provisioning/update-pos-dependencies.ps1`:

1. `-Stage`: staging copy, `composer update <packages> -W --no-dev`, and `composer audit` must be clean.
2. Verify the staging tree: `run-pos-e2e.ps1 -Mode isolated -AppRoot <app>-staging`, the same with `-Mode visitor`,
   and `run-pos-sim-recovery.ps1 -AppRoot <app>-staging`.
3. `-Promote`: about one minute of POS downtime. Copy-then-swap of `vendor`, cache rebuild, and a health and
   integrity smoke test; it rolls back automatically on failure.
4. `-Rollback` restores `vendor.prev` and `composer.lock.prev` at any time.

Last run: 2026-11-18 (Laravel 12.73.0; audit clean). Re-run `composer audit --locked --no-dev` in the app
directory periodically.

## Monitoring

`Portfolio - health monitor` (`monitor-portfolio.ps1`, installed by `install-monitor-task.ps1`) runs every
15 minutes as SYSTEM. It is read-only and checks:
- public HTTPS health: CRM `/api/health`, POS `/harborpine/health` (database, worker running, lag ≤ 15 min unless
  paused), portal `/healthz`, `/status/crm` and `/status/pos`;
- TLS certificate lifetime of at least 14 days with a valid chain;
- the 7 portfolio/Caddy services running;
- the latest CRM/POS backups: under 26 h old, with a `.sha256` file and task result 0;
- C: free space of at least 3 GB.

Each run appends a JSON line to `C:\srv\portfolio\logs\monitor-<yyyyMM>.jsonl` (12 months kept). A state change
writes to the Windows Application log, source `PortfolioMonitor`: event **1001** when a check starts failing,
**1000** when it recovers. To list recent events:
`Get-EventLog -LogName Application -Source PortfolioMonitor -Newest 20`.

## Portfolio portal (M7)

`scripts/provisioning/deploy-portal.ps1` stages `portal/site`, writes `config.js` from the host state (CRM
`live` while its API service runs; POS `live` only while the owner-approval flag
`C:\srv\portfolio\caddy\pos.public-enabled` exists; ERP `planned`), swaps it into `C:\srv\portfolio\portal\www`
(previous copies kept as `www.prev-*`, last 3), re-renders the portfolio Caddy site files (whole host Caddyfile
validated, graceful `caddy reload`) and smoke-tests the public site; any failure restores the previous site.

Same-origin status routes on the portal host: `/status/crm` → CRM `/api/health`; `/status/pos` → POS
`/harborpine/health` exists only while the POS approval flag exists (template block `# @if-flag pos.public-enabled`).
`activate-pos-public.ps1` refreshes the portal after activation and after a rollback.

