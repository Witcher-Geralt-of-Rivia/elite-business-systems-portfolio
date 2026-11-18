# Operations Handbook — Release 1.0 (CRM + POS + Portal)

For whoever operates the Windows host. Commands run in an elevated Windows PowerShell 5.1 session from the
repository root unless stated otherwise. `<VPS_IP>` is the server's public address (kept out of this public
repository); scripts read it from `$env:PUBLIC_IP` or from the rendered CRM site file.

## 1. Ground rules

1. **Never restart the Caddy service.** It is shared with an unrelated co-hosted application of the owner
   (D-016). Change portfolio sites only through `render-caddy-sites.ps1`, which validates the whole host
   Caddyfile and then runs a graceful `caddy reload`. Never edit the host Caddyfile.
2. **Never touch services that are not portfolio services:** the co-hosted application, remote-access tools,
   and other database services.
3. **Secrets** live only in `C:\srv\portfolio\secrets` (Administrators/SYSTEM). Never print them, never copy
   them into the repository, and never pass passwords on a command line (the scripts use environment
   variables).
4. **Destructive tests** run only against isolated database clones (`run-pos-e2e.ps1 -Mode isolated`, the
   recovery suite). Public tests are read-only (visitor) or clean up after themselves (CRM).
5. **Before any database repair:** take a verified backup, rehearse on a clone, then apply it through the
   application's own commands.

## 2. Public endpoints

| URL | Purpose | Expected |
|---|---|---|
| `https://portfolio.<VPS_IP>.sslip.io/` | portal | 200 |
| `https://portfolio.<VPS_IP>.sslip.io/status/crm` · `/status/pos` | live status (same-origin proxies) | 200 JSON |
| `https://crm.<VPS_IP>.sslip.io/` · `/api/health` | CRM UI · health | 200 · `{"status":"ok"}` |
| `https://pos.<VPS_IP>.sslip.io/sign-in` · `/harborpine/health` | POS sign-in · health | 200 · `{"status":"ok","database":true,"simulation":{…,"lag_seconds":n}}` |

Visitor entry: "Explore the live demo" on each sign-in page. The POS entry is `/showcase/enter`, rate-limited.

## 3. Services and dependencies

| Service | Account | Role | Depends on |
|---|---|---|---|
| `caddy` (shared) | `NT SERVICE\caddy` | TLS and routing for all sites | rendered site files in `C:\srv\portfolio\caddy` |
| `portfolio-crm-postgres` | NetworkService | PostgreSQL 16 cluster for the CRM (loopback) | — |
| `portfolio-crm-api` | LocalService | Fastify API plus the in-process CRM simulation worker | `portfolio-crm-postgres` |
| `portfolio-pos-mariadb` | NetworkService | MariaDB 11.8 for the POS (loopback) | — |
| `portfolio-pos-php-1`, `-2` | LocalService | php-cgi FastCGI workers (NexoPOS) | `portfolio-pos-mariadb` |
| `portfolio-pos-sim` | LocalService | POS live simulation worker (`hp:worker`) | `portfolio-pos-mariadb` |

- All portfolio services start automatically and are restarted by WinSW on failure (definitions in
  `infrastructure/windows/services`).
- Start order after a host restart: the databases, then the API and PHP workers, then the POS worker. WinSW
  retries cover ordering races.

**Scheduled tasks (SYSTEM):**

| Task | Schedule | Script (deployed copy in `C:\srv\portfolio\scripts`) |
|---|---|---|
| Portfolio - CRM nightly backup | 03:15 daily | `backup-crm.ps1 -VerifyRestore` |
| Portfolio - POS nightly backup | 03:45 daily | `backup-pos.ps1 -VerifyRestore` |
| Portfolio - health monitor | every 15 min | `monitor-portfolio.ps1` |

After editing a maintenance script in the repository, re-run its installer (`install-pos-backup-task.ps1`,
`install-monitor-task.ps1`) to refresh the deployed copy.

## 4. Daily checks (2 minutes)

```powershell
# Monitor: last results and any state changes
Get-Content ("C:\srv\portfolio\logs\monitor-{0:yyyyMM}.jsonl" -f (Get-Date)) -Tail 4
Get-EventLog -LogName Application -Source PortfolioMonitor -Newest 10
# Services and tasks
Get-Service portfolio-* | Format-Table Name, Status
Get-ScheduledTask | Where-Object TaskName -like 'Portfolio*' | Get-ScheduledTaskInfo | Format-Table TaskName, LastRunTime, LastTaskResult
```

Event **1001** means a check started failing; **1000** means it recovered. Monitor JSON lines name the failing check
and include a detail string.

## 5. Simulation control

**POS** (run in `C:\srv\portfolio\pos\app`):

```powershell
C:\srv\portfolio\pos\php\php.exe artisan hp:sim status     # paused?, watermark, lag
C:\srv\portfolio\pos\php\php.exe artisan hp:sim pause      # worker keeps running but processes nothing
C:\srv\portfolio\pos\php\php.exe artisan hp:sim resume     # catches up from the watermark, no duplicates
```

- The worker runs `hp:worker` (60 s tick). It recycles itself after 120 minutes or 192 MB with exit code 3,
  and WinSW restarts it after 30–60 s; that is normal.
- Stopping or starting `portfolio-pos-sim` is always safe: catch-up is idempotent (event ledger).

**CRM:**
- The simulation runs inside `portfolio-crm-api` while `CRM_SIMULATION=live` is set in its env file. Intensity
  is `CRM_SIM_INTENSITY`, currently 3; tick is `CRM_SIM_TICK_SECONDS`, 60.
- To pause, set `CRM_SIMULATION` to anything else and restart `portfolio-crm-api`. The state is persisted;
  re-enabling catches up to the current time.
- Status and integrity (from `C:\srv\portfolio\crm\api`, with the env file's variables loaded into the process):
  `node scripts/simulate.ts status`, `node scripts/simulate.ts integrity`.

**Never run** `simulate reset` or `hp:backfill` on production. They regenerate history, and the published
history is deliberately kept as generated.

## 6. Integrity checks

| App | Command | Expected |
|---|---|---|
| POS | `php artisan hp:integrity --json` (about 30 s) | `"checks": 43, "failing": []`; `money.paid_sales` = `dashboard_paid_sales` |
| POS | `php artisan hp:replay-check` | ledger = deterministic plan (missing/unexpected/time mismatch 0) |
| CRM | `node scripts/simulate.ts integrity` | 22 checks, `failing` empty |

Run them weekly and before and after any maintenance.

## 7. Deployments and changes

| Change | Command | Interruption |
|---|---|---|
| CRM API/UI | `scripts\provisioning\deploy-crm.ps1` (migrations, build, service restart, reload) | about 1 min CRM API restart |
| POS module (`apps/pos/modules/HarborPine`) | `scripts\provisioning\deploy-pos-module.ps1` (mirror, migrate, caches) | none (cache rebuild) |
| POS PHP dependencies | `scripts\provisioning\update-pos-dependencies.ps1 -Stage`, verify, then `-Promote` | about 1 min POS (see DEPLOYMENT.md) |
| Portal | `scripts\provisioning\deploy-portal.ps1` (atomic swap, smoke tests, automatic restore) | none |
| Caddy site templates | `scripts\provisioning\render-caddy-sites.ps1 -PublicIp <VPS_IP>` | none (graceful reload) |
| POS public/private | `activate-pos-public.ps1 -OwnerApproved` / `-Rollback` | `-Rollback` makes the POS private again |
| POS visitor access | `php artisan hp:showcase enable` / `disable` (enable rotates the visitor password) | none |

After any change, run the relevant suite:
- `scripts\verification\run-pos-e2e.ps1 -Mode visitor -BaseUrl https://pos.<VPS_IP>.sslip.io`;
- `scripts\verification\run-pos-e2e.ps1 -Mode isolated`;
- `scripts\verification\run-crm-public-e2e.ps1 -PublicIp <VPS_IP>`.

## 8. Maintenance calendar

| Interval | Task |
|---|---|
| Daily | glance at the monitor log and events (section 4) |
| Weekly | integrity checks (section 6); review `C:\srv\portfolio\logs\maintenance\backup-*.log` |
| Monthly | `composer audit --locked --no-dev` in the POS app and `npm audit --omit=dev` in `apps/crm/backend` and `apps/crm/frontend`; apply fixes with the staged procedures; run `measure-resources.ps1 -Minutes 10` |
| Quarterly | restore a backup into a scratch database by hand (beyond the nightly automatic check); review [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) |
| Automatic | TLS certificates (Caddy renews; the monitor alarms below 14 days); backup retention (14 days); monitor log retention (12 months); WinSW log rolling |

Windows Update reboots: services start automatically, and the simulations catch up. The ERP's WSL change and
any reboot planned for it need the owner's REBOOT decision.

## 9. Logs

| Path (host) | Content |
|---|---|
| `C:\srv\portfolio\logs\monitor-<yyyyMM>.jsonl` | monitor results |
| `C:\srv\portfolio\logs\maintenance\` | backup transcripts |
| `C:\srv\portfolio\logs\crm-api\` · `pos-php\` · `pos-sim\` | service wrapper logs (rolling) |
| `C:\srv\portfolio\pos\app\storage\logs\laravel-<date>.log` | NexoPOS application log. Refused visitor and probe requests appear here by design |
| `C:\srv\portfolio\logs\caddy-*-access.log` | per-site access logs (rolling 10 MB × 5) |

Expected noise in the NexoPOS log: "The registration has been explicitly disabled" and "Invalid username or password"
(probes and tests). Investigate anything else, especially repeated `ERROR` entries naming `ModulesService` or
`do-setup`, and any `HarborPine: installed-state cache race avoided` warning that shows up often.
