<#
.SYNOPSIS
  Simulation recovery suite on an ISOLATED clone of the POS database (the shared database is never written).

.DESCRIPTION
  Clones `nexopos` into `nexopos_simtest`, then on the next store day after the clone's watermark:
   1. concurrency: two engines advance the same window at the same time;
   2. crash: an engine is killed mid-day (taskkill /F) and the day is re-run;
   3. verification: hp:replay-check (ledger == deterministic plan), hp:integrity (all checks), and an explicit
      duplicate query (one ledger entry per order, one order per sale event).
  Artisan runs with environment overrides (no config cache, clone database, array cache) so production
  caches and data are untouched. The clone is dropped at the end unless -KeepDatabase.
#>
[CmdletBinding()]
param(
    [switch]$KeepDatabase,
    [int]$KillAfterSeconds = 25,
    # Application tree to run (e.g. a staging copy with updated dependencies); the clone is the only database written.
    [string]$AppRoot = 'C:\srv\portfolio\pos\app'
)
$ErrorActionPreference = 'Stop'
$app = $AppRoot
$php = 'C:\srv\portfolio\pos\php\php.exe'
$bin = 'C:\srv\portfolio\pos\mariadb\bin'
$secret = Get-Content 'C:\srv\portfolio\secrets\pos-mariadb.json' -Raw | ConvertFrom-Json
$db = 'nexopos_simtest'
$conn = @('-u', 'root', '-h', '127.0.0.1', '-P', "$($secret.port)", '--protocol=TCP')
$work = Join-Path $env:TEMP 'pos-sim-recovery'
New-Item -ItemType Directory -Force $work | Out-Null
$report = [ordered]@{}

function Invoke-Sql([string]$sql) {
    $ErrorActionPreference = 'Continue'
    $out = & (Join-Path $bin 'mariadb.exe') @conn -N -B $db -e $sql 2>&1 | Where-Object { "$_" -notmatch 'ssl' }
    if ($LASTEXITCODE -ne 0) { throw "sql failed: $out" }
    return $out
}
# Arguments must not contain spaces (Start-Process joins them unquoted): times are passed as 2026-11-19T13:00:00.
function Start-Artisan([string[]]$a, [string]$tag) {
    $p = Start-Process $php -ArgumentList (@('-d', 'memory_limit=512M', 'artisan') + $a) -WorkingDirectory $app -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $work "$tag.out") -RedirectStandardError (Join-Path $work "$tag.err")
    $null = $p.Handle   # PowerShell 5.1 only reports ExitCode if the handle was opened while the process ran
    return $p
}
function Invoke-Artisan([string[]]$a, [string]$tag) {
    $p = Start-Artisan $a $tag; $p.WaitForExit(); $p.Refresh()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = (Get-Content (Join-Path $work "$tag.out") -Raw); Err = (Get-Content (Join-Path $work "$tag.err") -Raw) }
}

$env:MYSQL_PWD = $secret.root_password
try {
    # ---- clone
    $dump = Join-Path $work 'clone.sql'
    $ErrorActionPreference = 'Continue'
    & (Join-Path $bin 'mariadb-dump.exe') @conn --single-transaction --default-character-set=utf8mb4 --result-file=$dump $secret.database 2>&1 | Where-Object { "$_" -notmatch 'ssl' }
    if ($LASTEXITCODE -ne 0) { throw 'dump failed' }
    & (Join-Path $bin 'mariadb.exe') @conn -e "DROP DATABASE IF EXISTS $db; CREATE DATABASE $db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON $db.* TO '$($secret.app_user)'@'127.0.0.1'; GRANT ALL PRIVILEGES ON $db.* TO '$($secret.app_user)'@'localhost';" 2>&1 | Out-Null
    # The client reads the file itself: piping through PowerShell 5.1 would re-encode non-ASCII text.
    & (Join-Path $bin 'mariadb.exe') @conn --default-character-set=utf8mb4 $db -e "source $($dump -replace '\\', '/')" 2>&1 | Where-Object { "$_" -notmatch 'ssl' }
    if ($LASTEXITCODE -ne 0) { throw 'restore into clone failed' }
    Remove-Item $dump
    $ErrorActionPreference = 'Stop'

    $env:APP_CONFIG_CACHE = Join-Path $work 'no-config-cache.php'
    $env:DB_DATABASE = $db
    $env:CACHE_DRIVER = 'array'; $env:CACHE_STORE = 'array'; $env:SESSION_DRIVER = 'array'
    Invoke-Sql "UPDATE harborpine_sim_state SET paused = 0 WHERE id = 1" | Out-Null

    $watermark = [datetime](Invoke-Sql "SELECT processed_until FROM harborpine_sim_state WHERE id = 1" | Select-Object -First 1)
    $day = $watermark.Date.AddDays(1)
    $d = $day.ToString('yyyy-MM-dd')
    $report.clone_watermark = $watermark.ToString('yyyy-MM-dd HH:mm:ss')
    $report.test_day = $d

    # ---- 1. two engines on the same window at once
    $p1 = Start-Artisan @('hp:advance', "--until=${d}T13:00:00") 'conc-1'
    $p2 = Start-Artisan @('hp:advance', "--until=${d}T13:00:00") 'conc-2'
    $p1.WaitForExit(); $p2.WaitForExit(); $p1.Refresh(); $p2.Refresh()
    $report.concurrent_exit_codes = "$($p1.ExitCode),$($p2.ExitCode)"
    $report.concurrent_errors = @((Get-Content (Join-Path $work 'conc-1.err'), (Join-Path $work 'conc-2.err') -ErrorAction SilentlyContinue) |
        Where-Object { $_ -match 'Duplicate entry|Deadlock|SQLSTATE' } | ForEach-Object { ($_ -replace '\s+', ' ').Trim().Substring(0, [Math]::Min(160, $_.Trim().Length)) } | Select-Object -Unique -First 3)
    $settle = Invoke-Artisan @('hp:advance', "--until=${d}T13:00:00") 'conc-settle'
    $report.concurrent_settle_exit = $settle.Code

    # ---- 2. crash mid-day, then recover
    $before = [int](Invoke-Sql "SELECT COUNT(*) FROM harborpine_sim_ledger" | Select-Object -First 1)
    $crash = Start-Artisan @('hp:advance', "--until=${d}T23:59:59") 'crash'
    Start-Sleep -Seconds $KillAfterSeconds
    $killedWhileRunning = -not $crash.HasExited
    $ErrorActionPreference = 'Continue'; taskkill /T /F /PID $crash.Id 2>&1 | Out-Null; $ErrorActionPreference = 'Stop'
    $atKill = [int](Invoke-Sql "SELECT COUNT(*) FROM harborpine_sim_ledger" | Select-Object -First 1)
    $report.crash_killed_while_running = $killedWhileRunning
    $report.crash_events_before_kill = $atKill - $before
    $report.crash_watermark_after_kill = (Invoke-Sql "SELECT processed_until FROM harborpine_sim_state WHERE id = 1" | Select-Object -First 1)
    $recover = Invoke-Artisan @('hp:advance', "--until=${d}T23:59:59") 'recover'
    $report.recovery_exit = $recover.Code
    $report.events_after_recovery = [int](Invoke-Sql "SELECT COUNT(*) FROM harborpine_sim_ledger" | Select-Object -First 1) - $before
    $report.watermark_after_recovery = (Invoke-Sql "SELECT processed_until FROM harborpine_sim_state WHERE id = 1" | Select-Object -First 1)

    # ---- 3. verification
    $replay = Invoke-Artisan @('hp:replay-check', '--days=2') 'replay'
    $report.replay_exit = $replay.Code
    $report.replay = ($replay.Out | ConvertFrom-Json)
    $report.duplicate_order_entries = [int](Invoke-Sql "SELECT COUNT(*) FROM (SELECT entity_id FROM harborpine_sim_ledger WHERE entity = 'order' GROUP BY entity_id HAVING COUNT(*) > 1) x" | Select-Object -First 1)
    $report.test_day_orders = [int](Invoke-Sql "SELECT COUNT(*) FROM nexopos_orders WHERE created_at >= '$d 00:00:00' AND created_at <= '$d 23:59:59'" | Select-Object -First 1)
    $report.test_day_sale_events = [int](Invoke-Sql "SELECT COUNT(*) FROM harborpine_sim_ledger WHERE kind = 'sale' AND entity = 'order' AND event_key LIKE '${d}:%'" | Select-Object -First 1)
    $integrity = Invoke-Artisan @('hp:integrity', '--json') 'integrity'
    $ij = $integrity.Out | ConvertFrom-Json
    $report.integrity_checks = $ij.checks
    $report.integrity_failing = @(if ($ij.failing -isnot [array]) { $ij.failing.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" } })
    $report.passed = ($report.replay_exit -eq 0 -and $integrity.Code -eq 0 -and $report.duplicate_order_entries -eq 0 -and
        $report.recovery_exit -eq 0 -and $report.test_day_orders -eq $report.test_day_sale_events)
} catch {
    $report.error = "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    $report.passed = $false
} finally {
    $ErrorActionPreference = 'Continue'
    foreach ($v in 'APP_CONFIG_CACHE', 'DB_DATABASE', 'CACHE_DRIVER', 'CACHE_STORE', 'SESSION_DRIVER') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
    if (-not $KeepDatabase) { & (Join-Path $bin 'mariadb.exe') @conn -e "DROP DATABASE IF EXISTS $db;" 2>&1 | Out-Null }
    Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
}
$report | ConvertTo-Json -Depth 5
if (-not $report.passed) { exit 1 }
