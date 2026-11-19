# ERPNext v16 on WSL1: proof-of-concept plan

**Status:** plan only. Nothing here has been executed. Stage 1 needs the owner's **REBOOT** decision. No WSL feature,
runtime component or reboot is enabled before that approval.

**Question this PoC answers:** can ERPNext/Frappe **v16.60.0**, with the `portfolio_sim` app, run reliably on this
Windows Server 2025 VM through WSL1, inside the host's spare resources and without degrading Release 1.0?

**Known constraints:**
- Frappe needs `fork` (gunicorn, RQ), Python 3.14 and Redis, so it has no native Windows runtime (R-002).
- The VM exposes no virtualisation extensions, so WSL2, Hyper-V and Docker are impossible (R-001). WSL1 translates
  Linux system calls without a VM.
- WSL1's weak spots are file-system speed, inotify and some socket options. The PoC keeps databases off WSL1
  where it can.

## Lessons from the Linux integration runs (GitHub Actions, 2026-11-18)

Before any change to Windows, the app was run on real ERPNext/Frappe v16.60.0 on a temporary Ubuntu 24.04 runner
(`.github/workflows/erp-integration.yml`; evidence in TEST_RESULTS "M5 — ERPNext integration on Linux"). That
validated the **application** on a supported Linux runtime. It says nothing about WSL1.

| Lesson | Consequence for the PoC |
|---|---|
| Frappe v16.60.0 + ERPNext v16.60.0 build and install on Ubuntu 24.04 with Python 3.14, Node 24, MariaDB 11.8 and Redis. Bench init plus apps took about 4 min; site creation with ERPNext 57 s (4 vCPU runner) | S2–S4 use the same versions; expect several times longer on WSL1 |
| MariaDB needs `character_set_server = utf8mb4` and `collation_server = utf8mb4_unicode_ci` (ERPNext's CI sets them at runtime) | the separate Windows MariaDB instance needs them **in its `my.ini`**, so they persist across restarts |
| `bench start` runs its own `redis_cache`/`redis_queue` from the bench's Redis configs; the distribution's Redis service must not occupy those ports | S3: install `redis-server` in WSL1 but do not start its system service |
| For tests: `bench --site <site> set-config allow_tests true`, `run-tests --skip-before-tests`, and `unittest-xml-reporting` for JUnit. **`--skip-test-records` makes run-tests exit 0 without running anything** in v16 | S5 uses the same commands, and its result is accepted only through the JUnit guard (7 tests, no failure, error or skip) |
| Six application defects were found and fixed on real ERPNext (packaging, Gender fixtures, queued Stock Reconciliation over 100 rows, mapper due dates from today, server-side price fetching, credit-note reconciliation journals dated today) | the app the PoC installs already passed these on Linux; any new S5 failure is more likely platform-related |
| Throughput on the Linux runner (4 vCPU): 3,068 events in about 786 s of execution, **about 3.9 events/s** including document validation and ledger posting (run 44425817273) | S6's threshold (0.35 events/s) leaves about an 11× margin for WSL1 overhead and the smaller host |
| The scheduler process was disabled for the tests (workers only). The live worker needs `bench --site <site> enable-scheduler` plus the `schedule` process | S8 runs the soak with the scheduler enabled |

**WSL1-specific work that Linux CI cannot validate** (all still open):
1. Enabling the WSL feature and the one reboot (S1), which needs the owner's approval.
2. Python 3.14 through `uv` inside WSL1, plus the build dependencies for `mysqlclient` and `pycups`.
3. The separate native Windows MariaDB 11.8 instance (service, `my.ini`, loopback port), and WSL1 → Windows loopback
   connectivity.
4. Redis, gunicorn (fork), RQ workers and the scheduler under WSL1 system-call translation (S5, S8).
5. Starting the bench at Windows boot. WSL1 has no systemd, so a Windows scheduled task or service must start
   `bench start` inside the distro, and restart it.
6. Throughput and resource use on this 3-vCPU host next to Release 1.0 (S6, S8).
7. Backups and monitoring for the ERP database, extending the existing scripts. A Caddy route only after a
   separate approval.

## Reboot readiness (read-only inspection, 2026-11-18; reboot **not** authorised)

| Item | State |
|---|---|
| Automatic start after boot | `caddy`, all 7 portfolio services, `practica-web` (delayed start), `practica-postgres`, `sshd`, RustDesk, AnyDesk and Jump Desktop Connect: Automatic and running. Remote Desktop: enabled (`fDenyTSConnections = 0`); `TermService` is Manual and trigger-started, as is standard on Windows Server |
| Restart on failure | Caddy, CRM API, POS PHP workers, POS worker, the co-hosted web app, AnyDesk and Jump Desktop have recovery actions. **The three database services (CRM PostgreSQL, POS MariaDB, co-hosted PostgreSQL) and sshd/RustDesk have none.** They start at boot but are not restarted if they crash. **Prepared, not applied:** `scripts\provisioning\set-db-service-recovery.ps1` (dry run by default) proposes restart after 10/30/60 s for the two portfolio databases; `-Apply` needs owner authorisation, and the co-hosted database is included only with `-IncludeCoHosted` |
| Backups | CRM 03:15 and POS 10:30 (verified, `.sha256`), co-hosted application's daily copy 02:30 (result 0). S0's preflight takes fresh verified CRM and POS backups immediately before the reboot; the co-hosted backup task is only checked (last result), never started by these scripts |
| Pending operations | no Windows Update or servicing reboot pending. `PendingFileRenameOperations` holds **120 queued operations: 116 deletions of print-spooler driver-cache folders (`spool\V4Dirs`, typically left by Remote Desktop printer redirection), 3 deletions of Chrome installer leftovers, 1 Edge Update log rotation. No Windows system file replacements**, so these are harmless and are applied at the next boot |
| Checklists | `preflight-reboot.ps1` (S0 gate) and `post-reboot-check.ps1` (S1 criterion). A trial run of the post-reboot checklist in today's state passed 25/25 (with `-ExpectWsl Disabled`) |
| WSL feature | Disabled (unchanged) |
| Provider out-of-band console | **cannot be verified from inside the VPS.** The owner must confirm access before approving S1 |

**Readiness result:** technically ready for S1, **conditional** on three owner actions:
1. confirm out-of-band console access;
2. choose the maintenance window;
3. approve REBOOT.

Optionally, also authorise the database recovery actions. Successful CI testing is not a reboot authorisation. At
the window, S0's preflight takes fresh backups and re-checks everything.

## Design for the PoC

| Component | Placement | Why |
|---|---|---|
| Frappe bench (Python 3.14 via `uv`, Node 24, gunicorn, RQ workers, scheduler, socketio) | WSL1 Ubuntu 24.04, bench under the Linux home directory (not `/mnt/c`) | Needs Linux; the WSL1 native file system is much faster than DrvFs |
| MariaDB 11.8 for ERPNext | **New**, separate native Windows instance, loopback only, own data directory, service and credentials | Frappe needs server settings (utf8mb4, collation, InnoDB options) that must not be applied to the POS instance; X-DB-1 |
| Redis-compatible cache and queue | Redis 7 from Ubuntu inside WSL1 (first choice); fallback: a native Windows Redis-compatible server | RQ needs Redis; WSL1 shares the Windows loopback network, so either placement is reachable |
| Web | gunicorn on loopback; Caddy site `erp.<VPS_IP>.sslip.io` only after the PoC passes and the owner approves public access | No public exposure during the PoC |

Fixed rules throughout: the CRM, POS, portal and co-hosted application are never stopped or reconfigured (apart from
the reboot itself). Caddy is only reloaded. The POS MariaDB instance is untouched.

## Stages and gates

Each stage has a pass criterion. A stage that fails stops the PoC (see "Failure criteria").

| Stage | Action | Pass criterion |
|---|---|---|
| S0 Preconditions | Owner confirms out-of-band console access and approves REBOOT plus a window. Record the Caddyfile SHA-256, then run `scripts\maintenance\preflight-reboot.ps1 -RunBackups` (fresh verified CRM and POS backups; services and auto-start; features; monitor; clean pushed checkpoint; the co-hosted application's backup task result) | preflight exits 0; owner confirmations recorded |
| S1 Feature and reboot | **WSL1 only:** `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart`, then one reboot at the approved time ([ERP_WSL1_REBOOT.md](ERP_WSL1_REBOOT.md)). Never `wsl --install`, VirtualMachinePlatform, Hyper-V or WSL2 | `scripts\verification\post-reboot-check.ps1 -ExpectWsl Enabled -CaddyfileSha256 <S0 hash>` exits 0 within 10 minutes of boot. It checks: all Release 1.0, co-hosted and remote-access services; the monitor; POS caught up, integrity 0 and no duplicate keys; CRM integrity 22/22; the co-hosted application reachable; Caddyfile unchanged; VirtualMachinePlatform, Hyper-V and HypervisorPlatform still Disabled |
| S2 Distro and toolchain | `wsl --set-default-version 1`; Ubuntu 24.04 imported as WSL1 (`wsl --import <name> <dir> <rootfs.tar.gz> --version 1`, rootfs from the official Ubuntu cloud images); `wsl -l -v` must show VERSION 1. Then `uv python install 3.14`, Node 24, yarn | `wsl -l -v` → VERSION 1; `python3.14 -c "import ssl, sqlite3, ctypes"` and `node -v` succeed in WSL1 |
| S3 Data services | separate MariaDB 11.8 service (loopback, own port and data directory); Redis in WSL1 | `redis-cli ping` → PONG from WSL1; WSL1 connects to the ERP MariaDB over loopback; Frappe's MariaDB settings check passes |
| S4 Bench and site | `bench init --frappe-branch v16.60.0`; `bench get-app erpnext --branch v16.60.0`; `bench get-app portfolio_sim <repo path>`; `bench new-site erp-poc.local`; `install-app erpnext`, `install-app portfolio_sim` | `bench --site erp-poc.local migrate` and `doctor` clean; app installed; `bench build` succeeds |
| S5 Platform smoke, then functional | **Before any history is generated**, WSL1 platform smoke P1–P6 (below). Then `bench --site erp-poc.local run-tests --app portfolio_sim --module portfolio_sim.tests.test_lifecycle --skip-before-tests --junit-xml-output …` (never `--skip-test-records`) | P1–P6 pass; JUnit shows 7 tests with none failed, errored or skipped; `portfolio-sim integrity` 36/36 at 0; `replay-check` clean |
| S6 Throughput | backfill one month (1,114–2,054 events per month in the plan) and measure | at least 0.35 events/s, so the full history (26,461 planned events, 15½ months) takes under 21 h |
| S7 Serving | gunicorn plus socketio on loopback; desk sign-in in a browser through an SSH or RDP-local browser | sign-in and Sales Invoice view work; median page time under 3 s on loopback |
| S8 Soak (24 h) | live worker on; `measure-resources.ps1` before and during | ERP steady RAM ≤ 1.8 GB; host CPU average +15 points at most; CRM/POS/portal median latency within +25 %; no monitor event 1001; at most one ERP process restart per day |

**WSL1 platform smoke (part of S5, before any data generation).** Each item has to pass on this host; any
platform-level failure is evaluated against F3/F4:

| ID | Test | Pass |
|---|---|---|
| P1 | system calls: `python3.14 -c` with `os.fork()`, `multiprocessing.Pool(4).map(...)`, a `socket` server/client on loopback, and `fcntl.flock` on a file in the bench | all complete; no `ENOSYS`/`EINVAL` |
| P2 | Redis: `bench start`'s `redis_cache` and `redis_queue`; `redis-cli -p <port> ping`, set/get, `INFO persistence` | PONG; values round-trip; no fork errors in the Redis logs |
| P3 | RQ workers: `bench --site … execute frappe.enqueue --args "['frappe.ping']"` on the short, default and long queues; `bench doctor` | jobs finish; `bench doctor` shows the workers |
| P4 | scheduler: `bench --site … enable-scheduler`, `schedule` process on; `Scheduled Job Log` gains entries within 5 minutes; `portfolio_sim.services.worker.tick` runs (idle while `live` is off) | entries appear; no scheduler errors |
| P5 | process recovery: kill one gunicorn worker and one RQ worker (`kill -9`); then stop and restart the whole bench | gunicorn respawns the worker, the RQ worker is restarted, and the site responds afterwards |
| P6 | boot autostart: the Windows-side task that starts `bench start` in the distro at boot (WSL1 has no systemd) is tested by terminating the distro (`wsl --terminate`) and starting it the same way | bench processes come back without manual steps |

Only after S0–S8 pass: full backfill on the production ERP site, browser E2E (to be written in M5 like the
CRM and POS suites), and public HTTPS. Each of these needs a separate owner approval for the public route.

## Failure criteria (any of these ends the PoC as failed)

| ID | Failure |
|---|---|
| F1 | The feature cannot be enabled, or Release 1.0 services do not recover within 10 minutes after the reboot (→ roll the feature back) |
| F2 | Python 3.14, Frappe or ERPNext dependencies cannot be installed or imported under WSL1 |
| F3 | `bench new-site`, `install-app erpnext` or `migrate` fail reproducibly for platform reasons (file locking, inotify, fork, sockets) |
| F4 | Integration tests fail for platform reasons (RQ or gunicorn workers crashing or hanging, scheduler not firing), not because of app defects |
| F5 | Throughput under 0.35 events/s, or median desk page times over 3 s |
| F6 | Resources over budget (RAM > 1.8 GB steady, or Release 1.0 latency degraded by more than 25 %, or any monitor failure caused by the ERP) |
| F7 | Instability: more than one ERP crash or restart per day during the soak |

App defects found in S5 are fixed in the repository and do not count as platform failures. Their test evidence is
recorded either way.

## Rollback

- Stop and disable the WSL distro's services (`wsl --terminate`), and stop and disable the ERP MariaDB service.
  Neither affects Release 1.0.
- To remove WSL entirely: `Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
  -NoRestart`, then one more reboot at an approved time.
- Disk: delete the distro (`wsl --unregister`) and the ERP MariaDB data directory.

## Alternatives if the PoC fails

| Option | What it takes | Trade-off |
|---|---|---|
| A1 Separate small Linux VPS (4 GB RAM, Ubuntu 24.04, bench or `frappe_docker`) | owner purchase; DNS stays sslip.io | standard, supported deployment; **costs money** (outside the $0 constraint, so an owner decision) |
| A2 Provider VM with nested virtualisation | provider plan change; then WSL2 or Docker on this host | supported container route; may cost; host migration risk |
| A3 Owner-run Linux machine with a tunnel | owner hardware | no hosting cost; availability depends on that machine |
| A4 Repository-only ERP (current state) | nothing | honest status "in preparation"; code, engine tests and static verification remain the evidence |

Native Windows Frappe is not an option (no `fork`).
