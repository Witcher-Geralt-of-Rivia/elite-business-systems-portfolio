# Runbook: ERPNext on native Windows (private phase)

**Decision:** owner decision ERP-RUNTIME = native Windows, REDIS-WINDOWS = community Redis 8.10.3 build
(2026-11-20, [DECISIONS.md](../DECISIONS.md) D-019). **Exposure:** private only (127.0.0.1). Public HTTPS needs a
separate owner approval.

> **Support status.** Frappe/ERPNext officially support Linux and macOS only. This installation runs the unmodified,
> pinned upstream code (Frappe v16.60.0 `bf9581a`, ERPNext v16.60.0 `886ab6a`) on Windows-native Python through a
> **project-maintained compatibility layer** (`scripts/erp-native/`). It is not a deployment platform Frappe supports;
> every Frappe/ERPNext upgrade must re-run the integration tests, the import probe and the browser tests before it
> is deployed (risk R-016).

## Topology

| Service (Windows, LOCAL SERVICE, automatic delayed start, restart on failure) | Process | Listens | Priority |
|---|---|---|---|
| `portfolio-erp-mariadb` | MariaDB 11.8.10 (own binaries and data directory, `lower_case_table_names=2`) | 127.0.0.1:3408 | normal |
| `portfolio-erp-redis-cache` | Redis 8.10.3 (redis-windows MSYS2 build), no persistence, LRU 192 MB, password | 127.0.0.1:13102 | normal |
| `portfolio-erp-redis-queue` | Redis 8.10.3, AOF everysec + RDB, `noeviction`, password | 127.0.0.1:11102 | normal |
| `portfolio-erp-web` | waitress + `frappe.app.application` (`serve_win.py`), 6 threads | 127.0.0.1:8851 | normal |
| `portfolio-erp-scheduler` | `frappe.utils.scheduler` loop (`scheduler_win.py`) | — | below normal |
| `portfolio-erp-worker-short` | `FrappeWorkerNoFork` + `TimerDeathPenalty` (`worker_win.py`), queues short, default | — | below normal |
| `portfolio-erp-worker-long` | same, queue long | — | below normal |
| `portfolio-erp-socketio` | Frappe's realtime server (Node 24) via `realtime_win.js` | 127.0.0.1:8852 | normal |
| `portfolio-erp-proxy` | private Caddy instance (own binary copy and config, admin API off): `/assets`, `/files` from disk, `/socket.io` → 8852, rest → 8851, `X-Frappe-Site-Name` | **127.0.0.1:8850** (entry point) | normal |

Site: `erp.portfolio.local` (production, private). Test site for the integration tests: `erp-test.portfolio.local`
(own database, `allow_tests`). Files: `C:\srv\portfolio\erp\runtime` (code, runtimes, data, logs),
`C:\srv\portfolio\backups\erp` (backups), `C:\srv\portfolio\secrets\erp-runtime.json` (DB root, Redis and
Administrator passwords; Administrators/SYSTEM only). The host Caddy is not involved.

## Compatibility adaptations (no upstream file changed)

| Unix assumption | Adaptation | Where |
|---|---|---|
| `signal.SIGKILL` etc. referenced at import | constants defined | `site-packages/sitecustomize.py` |
| `os.register_at_fork`, `faulthandler.register`, `os.nice` | no-ops (no fork; priority set per service) | `sitecustomize.py` |
| `import resource` (prepared reports) | `getrusage` from psutil's peak working set | `site-packages/resource.py` |
| `mysqlclient` has no Windows cp314 wheel | built with MSVC against MariaDB's client headers and `libmariadb` | `install-erp-runtime.ps1` |
| DB restore through a bash pipeline | `restore_database` streams SQL to `mariadb.exe` with the same filters | `frappe_win.py` |
| text files opened without encoding | `PYTHONUTF8=1` in every service and CLI call | services, `erp-ctl.ps1` |
| Jinja template names built with `\` | normalised to `/` | `frappe_win.py` |
| `preexec_fn` in `frappe.commands.popen` | below-normal creation flag | `frappe_win.py` |
| gunicorn | waitress (loopback only, trusted proxy 127.0.0.1) | `serve_win.py` |
| forking RQ worker, SIGALRM timeouts | `FrappeWorkerNoFork` + RQ `TimerDeathPenalty`; unrequested end of the work loop (job limit, job timeout) exits 3 so the service restarts it; 10 s idle Redis wait instead of 405 s (Windows handles the service's Ctrl+C only when the blocking read returns) | `worker_win.py` |
| a venv's `python.exe` on Windows is a launcher with the real interpreter as a child (orphaned workers after stops) | services run the base interpreter with `__PYVENV_LAUNCHER__` = the venv's `python.exe`: one process per service | `install-erp-services.ps1` |
| scheduler process exits when another holds the lock (supervisor restarts it on Linux) | retry loop instead of exit | `scheduler_win.py` |
| realtime server listens on all interfaces | listener pinned to 127.0.0.1 | `realtime_win.js` |
| MariaDB on Windows lower-cases table names | `lower_case_table_names=2` at data-directory creation | `install-erp-runtime.ps1` |
| front-end build (esbuild globbing, Studio Vite) fails on Windows | assets built on Linux CI from the pinned commits, installed with per-file SHA-256 verification | `erp-assets.yml`, `install-erp-assets.ps1` |
| `bench backup` uses shell pipelines | `backup-erp.ps1` (mariadb-dump, .NET gzip/zip, scratch-instance restore check) | `scripts/maintenance` |

## Install / rebuild (from an empty runtime directory)

```powershell
scripts\provisioning\install-erp-runtime.ps1        # downloads verified, Python, pinned sources, venv, MariaDB service, Redis configs
gh workflow run erp-assets.yml                       # Linux asset build from the pinned commits
scripts\provisioning\install-erp-assets.ps1 -RunId <run id>
scripts\provisioning\install-erp-services.ps1        # 8 WinSW services (not started)
scripts\maintenance\erp-ctl.ps1 start
scripts\provisioning\setup-erp-site.ps1              # production site; -Site erp-test.portfolio.local -Test for the test site
```

## Operate

```powershell
scripts\maintenance\erp-ctl.ps1 status                # services, PIDs, priority, memory, health endpoint
scripts\maintenance\erp-ctl.ps1 health                # GET /api/method/portfolio_sim.health.status (200 / 503)
scripts\maintenance\erp-ctl.ps1 stop | start | restart
scripts\maintenance\erp-ctl.ps1 frappe -- portfolio-sim status | integrity | replay-check | live on | pause | resume
scripts\maintenance\backup-erp.ps1 -VerifyRestore     # nightly task; -DeepVerify adds the app's integrity checks on the restore
scripts\verification\watch-erp-impact.ps1             # production-impact watchdog (pauses the simulation on degradation)
```

## Results

See [TEST_RESULTS.md](../TEST_RESULTS.md), section "M5 — Native Windows ERPNext (private)".
