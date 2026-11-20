<#
.SYNOPSIS
  Production-impact watchdog and resource log for the native-Windows ERPNext installation.

.DESCRIPTION
  Every -IntervalSec it appends one CSV row to <EvidenceDir>\watch-<start>.csv:
    host CPU %, available MB, commit %, ERP CPU % of the host (all ERP processes: python, mariadbd, redis-server, the
    proxy and the realtime node process; delta of CPU time), ERP working set and private MB, ERP data on disk (MB:
    database, sites, logs, queue persistence; refreshed every 10 min),
    ERP private-proxy ping latency and health (200/503), and the median latency (3 requests) of the production
    endpoints: CRM API health, portal health, POS health and the co-hosted application (URL from host-only config).
  Safety action "shed" (logged, never automatic resume):
    - available memory < -MinAvailableMB for 3 consecutive samples, or commit > -MaxCommitPct;
    - at least two production endpoints' rolling median (last 10 samples) above -LatencyLimit x baseline for 10
      consecutive samples.
    Shedding pauses the live simulation (portfolio-sim pause) and terminates running backfill processes (safe:
    every event is committed exactly once with its ledger row; a new backfill resumes at the first open event).
    The ERP web, workers and databases keep running.
  The latency baseline must come from this probe with the ERP load absent: -Calibrate (writes -BaselineFile).
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\srv\portfolio\erp\runtime',
    [string]$EvidenceDir = 'C:\srv\portfolio\erp\evidence\watch',
    [string]$BaselineFile = 'C:\srv\portfolio\erp\evidence\watch\baseline.json',
    [switch]$Calibrate,
    [int]$Samples = 20,
    [int]$IntervalSec = 30,
    [int]$MinAvailableMB = 1024,
    [int]$MaxCommitPct = 92,
    [double]$LatencyLimit = 1.25,
    [int]$ProxyPort = 8850,
    [double]$MaxHours = 96,
    [switch]$NoShed
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $EvidenceDir | Out-Null
$ip = (Select-String -Path C:\srv\portfolio\caddy\crm.caddy -Pattern 'crm\.(\d+\.\d+\.\d+\.\d+)\.sslip').Matches[0].Groups[1].Value
$targets = [ordered]@{
    crm    = "https://crm.$ip.sslip.io/api/health"
    portal = "https://portfolio.$ip.sslip.io/healthz"
    pos    = 'http://127.0.0.1:8820/harborpine/health'
}
$co = 'C:\srv\portfolio\config\cohosted.json'
if (Test-Path $co) { $u = (Get-Content $co -Raw | ConvertFrom-Json).url; if ($u) { $targets['cohosted'] = $u } }
$hist = @{}; foreach ($k in $targets.Keys) { $hist[$k] = [System.Collections.Generic.List[double]]::new() }
$ctl = Join-Path $PSScriptRoot '..\maintenance\erp-ctl.ps1'

function Get-Median([double[]]$x) { $s = $x | Sort-Object; return $s[[int][math]::Floor(($s.Count - 1) / 2)] }
function Write-Event([string]$msg) { $line = "$(Get-Date -Format o) $msg"; Add-Content (Join-Path $EvidenceDir 'events.log') $line; Write-Host $line }
function Get-Probe([string]$url) { $t = @(1..3 | ForEach-Object { [double](& curl.exe -s -o NUL -m 20 -w '%{time_total}' $url) * 1000 }); return [int](Get-Median $t) }
function Get-ErpProcesses {
    $rootPattern = [regex]::Escape($Root)
    Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='mariadbd.exe' OR Name='redis-server.exe' OR Name='caddy.exe' OR Name='node.exe'" |
        Where-Object { ($_.ExecutablePath -match "^$rootPattern") -or ($_.CommandLine -match 'realtime_win\.js') }
}

if ($Calibrate) {
    $running = @(Get-ErpProcesses | Where-Object { $_.CommandLine -match 'backfill|run-tests' })
    if ($running) { throw 'calibration needs the ERP load absent (backfill/test processes are running)' }
    for ($i = 0; $i -lt $Samples; $i++) {
        foreach ($k in $targets.Keys) { $hist[$k].Add((Get-Probe $targets[$k])) }
        Start-Sleep -Seconds ([math]::Max(1, $IntervalSec - 8))
    }
    $b = [ordered]@{ time = (Get-Date).ToString('o'); samples = $Samples; method = '3 requests per sample, median'; erp_services = @(Get-Service portfolio-erp-* -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running').Count }
    foreach ($k in $targets.Keys) { $b[$k] = Get-Median $hist[$k].ToArray() }
    $b | ConvertTo-Json | Set-Content $BaselineFile -Encoding ascii
    Write-Host "baseline written to $BaselineFile"; $b | Format-List; return
}
$baseline = Get-Content $BaselineFile -Raw | ConvertFrom-Json
$base = @{}; foreach ($k in $targets.Keys) { $base[$k] = [double]$baseline.$k }

$csv = Join-Path $EvidenceDir ("watch-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
Add-Content $csv ("time,host_cpu_pct,avail_mb,commit_pct,erp_cpu_pct,erp_ws_mb,erp_private_mb,erp_disk_mb,erp_ping_ms,erp_health," + (($targets.Keys | ForEach-Object { "${_}_ms" }) -join ',') + ',action')
$lowMem = 0; $slow = 0; $prev = @{}; $prevT = $null; $end = (Get-Date).AddHours($MaxHours); $diskMb = 0; $diskAt = [datetime]::MinValue
Write-Event "watchdog started: $csv (baseline $(($targets.Keys | ForEach-Object { "$_=$($base[$_])" }) -join ' '); min available $MinAvailableMB MB, max commit $MaxCommitPct %, latency x$LatencyLimit, shed=$(-not $NoShed))"
while ((Get-Date) -lt $end) {
  try {
    $c = (Get-Counter '\Processor(_Total)\% Processor Time', '\Memory\Available MBytes', '\Memory\Committed Bytes', '\Memory\Commit Limit' -SampleInterval 2 -MaxSamples 1).CounterSamples
    $hostCpu = [math]::Round($c[0].CookedValue, 1); $avail = [int]$c[1].CookedValue; $commit = [math]::Round(100 * $c[2].CookedValue / $c[3].CookedValue, 1)
    $now = Get-Date; $cpuNow = @{}; $ws = 0; $priv = 0
    foreach ($w in Get-ErpProcesses) {
        $p = Get-Process -Id $w.ProcessId -ErrorAction SilentlyContinue
        if ($p) { $cpuNow[$p.Id] = $p.CPU; $ws += $p.WorkingSet64; $priv += $p.PrivateMemorySize64 }
    }
    $erpCpu = ''
    if ($prevT) {
        $delta = 0.0; foreach ($id in $cpuNow.Keys) { if ($prev.ContainsKey($id)) { $delta += $cpuNow[$id] - $prev[$id] } }
        $erpCpu = [math]::Round(100 * $delta / ($now - $prevT).TotalSeconds / [Environment]::ProcessorCount, 1)
    }
    $prev = $cpuNow; $prevT = $now
    if (($now - $diskAt).TotalMinutes -ge 10) {
        # the growing parts only (database, site files, logs, queue persistence); code and runtimes are static
        # (sites\assets is excluded: its junctions lead into the static app trees)
        $grow = @('db', 'bench\logs', 'logs', 'redis-queue' | ForEach-Object { Join-Path $Root $_ }) +
            @(Get-ChildItem (Join-Path $Root 'bench\sites') -Directory | Where-Object Name -ne 'assets' | ForEach-Object FullName)
        $diskMb = [int]((Get-ChildItem $grow -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB); $diskAt = $now
    }
    $ping = [int]([double](& curl.exe -s -o NUL -m 20 -w '%{time_total}' "http://127.0.0.1:$ProxyPort/api/method/ping") * 1000)
    $health = & curl.exe -s -o NUL -m 30 -w '%{http_code}' "http://127.0.0.1:$ProxyPort/api/method/portfolio_sim.health.status"
    $lat = [ordered]@{}
    foreach ($k in $targets.Keys) { $lat[$k] = Get-Probe $targets[$k]; $hist[$k].Add($lat[$k]); if ($hist[$k].Count -gt 10) { $hist[$k].RemoveAt(0) } }
    $action = ''
    $lowMem = if ($avail -lt $MinAvailableMB) { $lowMem + 1 } else { 0 }
    $over = @($targets.Keys | Where-Object { $hist[$_].Count -ge 10 -and (Get-Median $hist[$_].ToArray()) -gt $LatencyLimit * $base[$_] })
    $slow = if ($over.Count -ge 2) { $slow + 1 } else { 0 }
    $reason = if ($lowMem -ge 3 -or $commit -gt $MaxCommitPct) { "memory: available $avail MB (x$lowMem), commit $commit %" } elseif ($slow -ge 10) { "latency over x$LatencyLimit on $($over -join ', ') for 10 samples" }
    if ($reason) {
        $action = if ($NoShed) { 'alert' } else { 'shed' }
        Write-Event "$($action.ToUpper()): $reason"
        if (-not $NoShed) {
            try { & $ctl frappe -LogFile (Join-Path $EvidenceDir 'shed-pause.log') -- portfolio-sim pause | Out-Null; Write-Event 'simulation paused' } catch { Write-Event "pause failed: $_" }
            foreach ($b in @(Get-ErpProcesses | Where-Object { $_.CommandLine -match 'portfolio-sim backfill' })) {
                Stop-Process -Id $b.ProcessId -Force -ErrorAction SilentlyContinue; Write-Event "backfill process $($b.ProcessId) terminated"
            }
        }
        $slow = 0; $lowMem = 0
    }
    Add-Content $csv ("{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11}" -f (Get-Date -Format s), $hostCpu, $avail, $commit, $erpCpu, [int]($ws / 1MB), [int]($priv / 1MB), $diskMb, $ping, $health, ($lat.Values -join ','), $action)
  } catch {
    # One bad sample (e.g. an invalid performance-counter read) must not end a multi-day watch.
    Write-Event "sample error (continuing): $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
  }
    Start-Sleep -Seconds ([math]::Max(1, $IntervalSec - 10))
}
Write-Event 'watchdog stopped'
