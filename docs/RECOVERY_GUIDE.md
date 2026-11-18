# Recovery Guide — Release 1.0 (CRM + POS + Portal)

Backups, restores, rollback commands and incident playbooks. Read [OPERATIONS_HANDBOOK.md §1](OPERATIONS_HANDBOOK.md#1-ground-rules)
first: never restart Caddy, never touch non-portfolio services, never expose secrets.

**What is exercised and what is not:**
- **Exercised every night:** each backup is restored into a scratch database and compared with the live one.
- **Not yet rehearsed:** replacing a *production* database from a backup (procedures 3.2 and 3.3). Rehearse
  on a scratch database first, every time.

## 1. Backups

| | CRM | POS |
|---|---|---|
| Task / time | Portfolio - CRM nightly backup, 03:15 | Portfolio - POS nightly backup, 03:45 |
| Script | `scripts/maintenance/backup-crm.ps1 -VerifyRestore` | `scripts/maintenance/backup-pos.ps1 -VerifyRestore` |
| Method | `pg_dump -Fc -Z 6` of database `crm` | `mariadb-dump --single-transaction --routines --triggers` (utf8mb4) of `nexopos` |
| File | `C:\srv\portfolio\backups\crm\crm-<yyyyMMdd-HHmmss>.dump` (+ `.sha256`) | `C:\srv\portfolio\backups\pos\pos-<yyyyMMdd-HHmmss>.sql` (+ `.sha256`) |
| Size | about 1.3 MB | about 103 MB |
| Nightly verification | restore into `crm_restore_check`; row counts of 9 tables equal | restore into `pos_restore_check`; row counts of 7 tables; CRC checksums of text columns in 5 tables |
| Retention | 14 days | 14 days |
| Log | `C:\srv\portfolio\logs\maintenance\backup-crm-<date>.log` | `…\backup-pos-<date>.log` |

**Ad-hoc backup** (for example before maintenance), elevated:
`powershell -File scripts\maintenance\backup-pos.ps1 -VerifyRestore` (the CRM equivalent is analogous). It exits 0
only if the restore check passed.

**Verify a file's checksum:**
`(Get-FileHash <file> -Algorithm SHA256).Hash.ToLower()` must equal the first field of `<file>.sha256`.

**Off-host copies:** none (see KNOWN_LIMITATIONS). The owner should copy the newest dumps to separate storage if
the VPS itself is at risk.

## 2. Rollback commands

| Situation | Command | Effect |
|---|---|---|
| POS must stop being public | `scripts\provisioning\activate-pos-public.ps1 -Rollback` | removes the approval flag, renders the loopback-only POS site, graceful reload, portal POS card back to "being finalised" |
| POS dependency update misbehaves | `scripts\provisioning\update-pos-dependencies.ps1 -Rollback` | restores `vendor.prev`, `composer.lock.prev` and the package manifests; caches rebuilt; services restarted (about 1 min) |
| Bad Caddy render | automatic in `render-caddy-sites.ps1` | a failed validation restores the previous site files; nothing is reloaded |
| Bad portal deploy | automatic in `deploy-portal.ps1` | failed smoke tests restore the previous `www` (last 3 copies kept as `www.prev-<stamp>`) |
| Bad POS module change | `git checkout <good commit> -- apps/pos/modules/HarborPine` then `deploy-pos-module.ps1` | the module is mirrored from the repository; module migrations are additive (`down()` exists for the index migration) |
| Bad CRM deploy | `git checkout <good commit>` then `deploy-crm.ps1` | rebuilds and redeploys the API and UI. Database migrations are forward-only: restore from backup (3.2) if a migration must be undone |
| POS visitor access must stop | `php artisan hp:showcase disable` (in `C:\srv\portfolio\pos\app`) | visitor entry refused; existing visitor sessions lose access |
| CRM visitor access must stop | set `CRM_SHOWCASE` to anything but `on` in `crm-api.env`, restart `portfolio-crm-api` | visitor entry refused |

## 3. Restore procedures

### 3.1 Inspect a backup without touching production (both apps)

The nightly scripts do exactly this. To restore a *chosen* file into a scratch database by hand:

```powershell
# POS (MariaDB) — the client must read the file itself (no PowerShell pipe: it re-encodes non-ASCII text)
$s = Get-Content C:\srv\portfolio\secrets\pos-mariadb.json -Raw | ConvertFrom-Json; $env:MYSQL_PWD = $s.root_password
$m = 'C:\srv\portfolio\pos\mariadb\bin\mariadb.exe'; $c = @('-u','root','-h','127.0.0.1','-P',"$($s.port)",'--protocol=TCP')
& $m @c -e "DROP DATABASE IF EXISTS pos_inspect; CREATE DATABASE pos_inspect CHARACTER SET utf8mb4;"
& $m @c --default-character-set=utf8mb4 pos_inspect -e "source C:/srv/portfolio/backups/pos/pos-<stamp>.sql"
# ...inspect, then: & $m @c -e "DROP DATABASE pos_inspect;"; Remove-Item Env:MYSQL_PWD

# CRM (PostgreSQL)
$s = Get-Content C:\srv\portfolio\secrets\crm-postgres.json -Raw | ConvertFrom-Json; $env:PGPASSWORD = $s.superuser_password
$b = 'C:\Program Files\PostgreSQL\16\bin'; $c = @('-h','127.0.0.1','-p',"$($s.port)",'-U',$s.superuser)
& "$b\createdb.exe" @c -O crm_owner crm_inspect
& "$b\pg_restore.exe" @c -d crm_inspect --exit-on-error C:\srv\portfolio\backups\crm\crm-<stamp>.dump
# ...inspect, then: & "$b\dropdb.exe" @c crm_inspect; Remove-Item Env:PGPASSWORD
```

### 3.2 Replace the CRM production database (not yet rehearsed)

1. Take a fresh backup (`backup-crm.ps1 -VerifyRestore`) so that the current state is recoverable too.
2. Restore the chosen dump into `crm_inspect` (3.1). Run `simulate integrity` against it by pointing
   `CRM_DATABASE_URL` at it in a throwaway shell, and confirm the expected data is present.
3. Stop `portfolio-crm-api` (the CRM is unavailable from here).
4. Rename the databases: `ALTER DATABASE crm RENAME TO crm_replaced; ALTER DATABASE crm_inspect RENAME TO crm;`
   (as the superuser, with no connections open).
5. Start `portfolio-crm-api`. Check `/api/health`, `simulate integrity` (22/22) and the public E2E.
6. Keep `crm_replaced` until the restored state is accepted, then drop it.

The simulation state lives in the database, so the restored database resumes from its own clock and catches up.

### 3.3 Replace the POS production database (not yet rehearsed)

1. `php artisan hp:sim pause`, then a fresh `backup-pos.ps1 -VerifyRestore`.
2. Restore the chosen dump into `pos_inspect` (3.1) and inspect it.
3. Stop `portfolio-pos-sim`, `portfolio-pos-php-1` and `portfolio-pos-php-2` (the POS is unavailable from
   here; Caddy answers 502).
4. As root:
   `DROP DATABASE nexopos; CREATE DATABASE nexopos CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;`
   then `source` the dump into `nexopos`, as in 3.1.
   The `nexopos_app` grants are stored per database name and survive the drop/create; verify them with
   `SHOW GRANTS FOR 'nexopos_app'@'127.0.0.1'`.
5. Start the PHP services, run `php artisan optimize:clear` then `php artisan optimize`, and start
   `portfolio-pos-sim`. Then `php artisan hp:sim resume`.
6. Verify: `hp:integrity` 43/43, `hp:replay-check`, health, and the public visitor suite.

## 4. Incident playbooks

| Signal | First steps |
|---|---|
| Event 1001 `crm.health` / `pos.health` / `portal.health` | `Get-Service portfolio-*`. Read the newest service wrapper log (`C:\srv\portfolio\logs\<service>\`) and the NexoPOS log. Start the stopped service. If a site answers 502, check its PHP or API service. Do not restart Caddy |
| `pos.health` with a growing `lag` | `hp:sim status`; restart `portfolio-pos-sim` (safe); check `logs\pos-sim` for exceptions. A paused simulation is reported as healthy |
| Event 1001 `tls.*` (fewer than 14 days left) | Caddy renews automatically. Check that the hostname still resolves (sslip.io) and look in Caddy's own log for ACME errors. Note the Let's Encrypt rate limits (R-007). A `caddy reload` via the render script is allowed; a restart is not |
| Event 1001 `backup.*` | open the task's transcript in `logs\maintenance`; run the backup by hand with `-VerifyRestore`; check free disk space |
| Event 1001 `disk.c` (under 3 GB) | delete old `www.prev-*`, `vendor.prev` and test dumps in `%TEMP%`. Reduce backup retention only after copying dumps off the host |
| Integrity check failing | do not repair on production directly. Back up, clone (the E2E/recovery runners show how), reproduce, fix through the module or API code, rehearse on the clone, then apply. Record everything in TEST_RESULTS |
| Visitors redirected to the installer / empty POS catalogue | should not happen since M8 (installed-state fix). Check the module is enabled (`modules:enable HarborPine`) and look for `installed-state cache race avoided` warnings |
| Suspected credential exposure | owner action (SEC-ROTATE). Rotate from a trusted device; application secrets live in `C:\srv\portfolio\secrets`. `hp:showcase enable` rotates the POS visitor password; the CRM visitor account has no password by design |
| POS must go offline quickly | `activate-pos-public.ps1 -Rollback` (graceful; the CRM and co-hosted app are unaffected) |
