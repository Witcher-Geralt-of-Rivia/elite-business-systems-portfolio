<#
.SYNOPSIS
  Generates the ERP history up to -Until in small chunks, yielding to production: the safe way to run a long backfill.

.DESCRIPTION
  Loop (run it as a SYSTEM job; see erp-ctl.ps1 job or a one-off task):
    - while the impact watchdog's hold file exists (a production application or memory was over its limit), wait;
      the watchdog removes it after 10 consecutive healthy samples;
    - otherwise run `portfolio-sim backfill --until <Until> --max-events <ChunkEvents>` at BELOW NORMAL priority
      (deterministic, idempotent continuation from the last committed event; deadlocks are retried by the engine);
    - stop when a chunk executes nothing (the history has reached -Until).
  For the duration, the ERP's own MariaDB process runs at BELOW NORMAL priority too (restored to Normal at the end; a
  service restart also restores it). A chunk killed by the watchdog is not an error: the next chunk resumes at the
  first open event. Progress: <Root>\logs\jobs\backfill-progress.csv (time, events, processed_until, chunk seconds,
  events/s, hold waits). Only one runner may run (lock file).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Until,
    [int]$ChunkEvents = 200,
    [string]$Root = 'C:\srv\portfolio\erp\runtime',
    [string]$Site = 'erp.portfolio.local',
    [string]$HoldFile = 'C:\srv\portfolio\erp\hold.json',
    [int]$MaxConsecutiveFailures = 3
)
$ErrorActionPreference = 'Stop'
$ctl = Join-Path $PSScriptRoot 'erp-ctl.ps1'
$jobs = Join-Path $Root 'logs\jobs'; New-Item -ItemType Directory -Force $jobs | Out-Null
$progress = Join-Path $jobs 'backfill-progress.csv'
$lockPath = Join-Path $jobs 'backfill-runner.lock'
$lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')   # exclusive: a second runner fails here
if (-not (Test-Path $progress)) { Add-Content $progress 'time,ledger_rows,processed_until,executed,chunk_s,events_per_s,hold_wait_s,exit' }

function Set-DbPriority([string]$class) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='portfolio-erp-mariadb'"
    if ($svc.ProcessId) { try { (Get-Process -Id $svc.ProcessId).PriorityClass = $class } catch { Write-Host "db priority: $_" } }
}
function Get-Status {
    $log = Join-Path $jobs 'backfill-status.log'
    & $ctl frappe -Root $Root -Site $Site -LogFile $log -- portfolio-sim status | Out-Null
    $t = Get-Content $log -Raw; $t = $t.Substring($t.IndexOf('{'), $t.LastIndexOf('}') - $t.IndexOf('{') + 1)
    return $t | ConvertFrom-Json
}

$failures = 0; $holdWait = 0
try {
    while ($true) {
        if (Test-Path $HoldFile) { Start-Sleep -Seconds 30; $holdWait += 30; continue }
        Set-DbPriority 'BelowNormal'
        $chunkLog = Join-Path $jobs 'backfill-chunk.log'
        $t0 = Get-Date
        & $ctl frappe -Root $Root -Site $Site -LogFile $chunkLog -- portfolio-sim backfill --until $Until --max-events $ChunkEvents | Out-Null
        $code = $LASTEXITCODE; $secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        $executed = 0
        $text = Get-Content $chunkLog -Raw
        $skipped = 0
        if ($code -eq 0 -and $text -match '"executed":\s*(\d+)') { $executed = [int]$Matches[1] }
        if ($code -eq 0 -and $text -match '"skipped_already_done":\s*(\d+)') { $skipped = [int]$Matches[1] }
        $st = Get-Status
        Add-Content $progress ("{0},{1},{2},{3},{4},{5},{6},{7}" -f (Get-Date -Format s), $st.ledger_rows, $st.processed_until, $executed, $secs,
            $(if ($secs -gt 0) { [math]::Round($executed / $secs, 3) } else { 0 }), $holdWait, $code)
        $holdWait = 0
        if ($code -ne 0) {
            if (Test-Path $HoldFile) { continue }             # stopped by the watchdog: wait for the release
            $failures++
            Copy-Item $chunkLog (Join-Path $jobs ("backfill-failure-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date)))
            if ($failures -ge $MaxConsecutiveFailures) { throw "backfill failed $failures times in a row (see backfill-failure-*.log); last error: $($st.last_error)" }
            Start-Sleep -Seconds 60; continue
        }
        $failures = 0
        if ($executed -eq 0 -and $skipped -eq 0) { Write-Host "history complete up to $Until (ledger rows $($st.ledger_rows))"; break }
    }
} finally {
    Set-DbPriority 'Normal'
    $lock.Dispose(); Remove-Item $lockPath -ErrorAction SilentlyContinue
}
