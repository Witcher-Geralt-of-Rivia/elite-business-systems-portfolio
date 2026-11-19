<#
.SYNOPSIS
  Safety watchdog and resource log for the ERPNext QEMU-TCG guest. Run it for as long as the guest runs.

.DESCRIPTION
  Every -IntervalSec it appends one CSV row to <Root>\logs\watch-<date>.csv:
    host CPU %, available MB, commit % of limit, QEMU CPU % of one core (delta), QEMU working set / private MB,
    overlay disk MB, and median latency (3 requests) of the production endpoints: CRM API health, portal health,
    POS health (loopback) and the co-hosted application (URL from the host-only config).
  Safety actions (the guest's state is kept in every case):
    - available memory < -MinAvailableMB for 3 consecutive samples, or commit > -MaxCommitPct: clean guest shutdown
      (QMP system_powerdown), then the watchdog exits;
    - production latency: when at least two endpoints' rolling median (last 10 samples) exceeds -LatencyLimit x the
      baseline median for 10 consecutive samples, the guest is PAUSED (QMP stop) and stays paused until resumed by
      hand (QMP cont).
  The latency baseline must come from this same probe (3 requests per sample, one sample per interval) with the guest
  stopped or paused: -Calibrate takes -Samples samples and writes it to -BaselineFile. (A baseline from a different
  method - e.g. measure-resources.ps1's back-to-back requests on warm caches - reads ~25-50 % lower and makes the
  latency rule pause the guest spuriously; measured 2026-11-19.)
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\srv\portfolio\erp\qemu-poc',
    [string]$BaselineFile = 'C:\srv\portfolio\erp\qemu-poc\evidence\watch-baseline.json',
    [switch]$Calibrate,
    [int]$Samples = 20,
    [int]$IntervalSec = 30,
    [int]$MinAvailableMB = 1024,
    [int]$MaxCommitPct = 92,
    [double]$LatencyLimit = 1.25,
    [int]$QmpPort = 8831,
    [int]$MaxHours = 72
)
$ErrorActionPreference = 'Stop'
$pidFile = Join-Path $Root 'vm\qemu.pid'; $disk = Join-Path $Root 'vm\erp.qcow2'; $logDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$ip = (Select-String -Path C:\srv\portfolio\caddy\crm.caddy -Pattern 'crm\.(\d+\.\d+\.\d+\.\d+)\.sslip').Matches[0].Groups[1].Value
$targets = [ordered]@{
    crm    = @{ url = "https://crm.$ip.sslip.io/api/health"; base = 'crm public /api/health' }
    portal = @{ url = "https://portfolio.$ip.sslip.io/healthz"; base = 'portal public /healthz' }
    pos    = @{ url = 'http://127.0.0.1:8820/harborpine/health'; base = 'pos loopback /harborpine/health' }
}
$co = 'C:\srv\portfolio\config\cohosted.json'
if (Test-Path $co) { $u = (Get-Content $co -Raw | ConvertFrom-Json).url; if ($u) { $targets['cohosted'] = @{ url = $u; base = 'co-hosted application' } } }
$hist = @{}; foreach ($k in $targets.Keys) { $hist[$k] = [System.Collections.Generic.List[double]]::new() }

function Send-Qmp([string]$execute) {
    $c = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $QmpPort)
    try {
        $s = $c.GetStream(); $r = [System.IO.StreamReader]::new($s); $w = [System.IO.StreamWriter]::new($s); $w.AutoFlush = $true
        $null = $r.ReadLine(); $w.WriteLine('{"execute":"qmp_capabilities"}'); $null = $r.ReadLine()
        $w.WriteLine("{`"execute`":`"$execute`"}"); return $r.ReadLine()
    } finally { $c.Close() }
}
function Get-Median([double[]]$x) { $s = $x | Sort-Object; return $s[[int][math]::Floor(($s.Count - 1) / 2)] }
function Write-Event([string]$msg) { $line = "$(Get-Date -Format o) $msg"; Add-Content (Join-Path $logDir 'watch-events.log') $line; Write-Host $line }

function Get-Probe([string]$url) { $t = @(1..3 | ForEach-Object { [double](& curl.exe -s -o NUL -m 20 -w '%{time_total}' $url) * 1000 }); return [int](Get-Median $t) }

if ($Calibrate) {
    $q = $null; try { $q = Send-Qmp 'query-status' } catch { }
    if ($q -and $q -match '"running": true') { throw 'calibration needs the guest stopped or paused (QMP stop)' }
    for ($i = 0; $i -lt $Samples; $i++) {
        foreach ($k in $targets.Keys) { $hist[$k].Add((Get-Probe $targets[$k].url)) }
        Start-Sleep -Seconds ([math]::Max(1, $IntervalSec - 8))
    }
    $b = [ordered]@{ time = (Get-Date).ToString('o'); samples = $Samples; method = '3 requests per sample, median' }
    foreach ($k in $targets.Keys) { $b[$k] = Get-Median $hist[$k].ToArray() }
    $b | ConvertTo-Json | Set-Content $BaselineFile -Encoding ascii
    Write-Host "baseline written to $BaselineFile"; $b | Format-List; return
}
$baseline = Get-Content $BaselineFile -Raw | ConvertFrom-Json
foreach ($k in @($targets.Keys)) { $targets[$k].baseMs = [double]$baseline.$k }

$csv = Join-Path $logDir ("watch-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
Add-Content $csv ("time,host_cpu_pct,avail_mb,commit_pct,qemu_cpu_pct,qemu_ws_mb,qemu_private_mb,disk_mb," + (($targets.Keys | ForEach-Object { "${_}_ms" }) -join ',') + ',action')
$lowMem = 0; $slow = 0; $prevCpu = $null; $prevT = $null; $end = (Get-Date).AddHours($MaxHours)
Write-Event "watchdog started: $csv (baseline $(($targets.Keys | ForEach-Object { "$_=$($targets[$_].baseMs)" }) -join ' '); min available $MinAvailableMB MB, max commit $MaxCommitPct %, latency limit x$LatencyLimit)"
while ((Get-Date) -lt $end) {
    $c = (Get-Counter '\Processor(_Total)\% Processor Time', '\Memory\Available MBytes', '\Memory\Committed Bytes', '\Memory\Commit Limit' -SampleInterval 2 -MaxSamples 1).CounterSamples
    $hostCpu = [math]::Round($c[0].CookedValue, 1); $avail = [int]$c[1].CookedValue; $commit = [math]::Round(100 * $c[2].CookedValue / $c[3].CookedValue, 1)
    $p = $null; if (Test-Path $pidFile) { $p = Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue }
    $qCpu = ''; $ws = ''; $priv = ''
    if ($p) {
        $now = Get-Date
        if ($null -ne $prevCpu) { $qCpu = [math]::Round(100 * ($p.CPU - $prevCpu) / ($now - $prevT).TotalSeconds, 1) }
        $prevCpu = $p.CPU; $prevT = $now; $ws = [int]($p.WorkingSet64 / 1MB); $priv = [int]($p.PrivateMemorySize64 / 1MB)
    } else { $prevCpu = $null }
    $diskMb = if (Test-Path $disk) { [int]((Get-Item $disk).Length / 1MB) } else { '' }
    $lat = [ordered]@{}
    foreach ($k in $targets.Keys) {
        $lat[$k] = Get-Probe $targets[$k].url; $hist[$k].Add($lat[$k]); if ($hist[$k].Count -gt 10) { $hist[$k].RemoveAt(0) }
    }
    $action = ''
    $lowMem = if ($avail -lt $MinAvailableMB) { $lowMem + 1 } else { 0 }
    $over = @($targets.Keys | Where-Object { $hist[$_].Count -ge 10 -and (Get-Median $hist[$_].ToArray()) -gt $LatencyLimit * $targets[$_].baseMs })
    $slow = if ($over.Count -ge 2) { $slow + 1 } else { 0 }
    if ($p -and ($lowMem -ge 3 -or $commit -gt $MaxCommitPct)) {
        $action = 'shutdown'; Write-Event "STOP: available $avail MB (x$lowMem), commit $commit % -> guest shutdown"
        try { Write-Event (Send-Qmp 'system_powerdown') } catch { Write-Event "QMP failed: $_" }
    } elseif ($p -and $slow -ge 10) {
        $action = 'pause'; Write-Event "PAUSE: production latency over x$LatencyLimit baseline for 10 samples on $($over -join ', ') -> guest paused (QMP cont to resume)"
        try { Write-Event (Send-Qmp 'stop') } catch { Write-Event "QMP failed: $_" }; $slow = 0
    }
    Add-Content $csv ("{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}" -f (Get-Date -Format s), $hostCpu, $avail, $commit, $qCpu, $ws, $priv, $diskMb, ($lat.Values -join ','), $action)
    if ($action -eq 'shutdown') { break }
    Start-Sleep -Seconds ([math]::Max(1, $IntervalSec - 8))
}
Write-Event 'watchdog stopped'
