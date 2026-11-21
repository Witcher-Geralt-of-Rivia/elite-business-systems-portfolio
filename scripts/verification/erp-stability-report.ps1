<#
.SYNOPSIS
  Evaluates an observed stability window for the native-Windows ERPNext installation from recorded evidence.

.DESCRIPTION
  For [-From, -To] (a real, already elapsed period) it reports:
    - production latency and availability per existing application and host/ERP resources (erp-impact-report.ps1)
    - watchdog actions (shed / release) and sample errors in the window
    - health-monitor runs: failing checks per run (portfolio and ERP checks)
    - service restarts: Service Control Manager events for portfolio-erp-* services (unexpected terminations = 7031/7034,
      started/stopped = 7036) and worker restart exits (code 3) in the wrapper logs
    - live simulation: ledger rows at the start and end of the window (watchdog column), events executed in the window
    - final integrity (36 checks) and replay (exact) results, run at the end
  Writes <EvidenceDir>\stability-<from>.json. It refuses a window that has not ended yet.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][datetime]$From,
    [Parameter(Mandatory)][datetime]$To,
    [string]$EvidenceDir = 'C:\srv\portfolio\erp\evidence\native',
    [string]$BaselineFile = 'C:\srv\portfolio\erp\evidence\watch\baseline.json'
)
$ErrorActionPreference = 'Stop'
if ((Get-Date) -lt $To) { throw "the window ends at $To and has not elapsed yet" }
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$ctl = Join-Path $repo 'scripts\maintenance\erp-ctl.ps1'
$out = [ordered]@{ from = $From.ToString('s'); to = $To.ToString('s'); hours = [math]::Round(($To - $From).TotalHours, 2) }

# Latency, availability, resources
$impact = Join-Path $EvidenceDir ("stability-{0:yyyyMMdd-HHmm}-impact.json" -f $From)
& (Join-Path $PSScriptRoot 'erp-impact-report.ps1') -From $From -To $To -Label 'stability window' -BaselineFile $BaselineFile -Json $impact | Out-Null
$out['impact'] = Get-Content $impact -Raw | ConvertFrom-Json

# Watchdog events
$out['watchdog_events'] = @(Get-Content 'C:\srv\portfolio\erp\evidence\watch\events.log' | Where-Object {
        $_ -match '^(\S+) ' -and ([datetime]$Matches[1]) -ge $From -and ([datetime]$Matches[1]) -le $To -and $_ -match 'SHED|RELEASE|sample error|resumed|paused' })

# Health monitor
$mon = foreach ($f in Get-ChildItem 'C:\srv\portfolio\logs' -Filter 'monitor-*.jsonl') { Get-Content $f.FullName | ConvertFrom-Json | Where-Object { [datetime]$_.time -ge $From -and [datetime]$_.time -le $To } }
$out['monitor'] = [ordered]@{ runs = @($mon).Count; failing_runs = @($mon | Where-Object { -not $_.ok }).Count
    failing_checks = @($mon | Where-Object { -not $_.ok } | ForEach-Object { "$([datetime]$_.time | Get-Date -Format s): $($_.failing -join ',')" }) }

# Service restarts
$scm = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = $From; EndTime = $To } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'Portfolio ERP' })
$out['service_events'] = [ordered]@{ unexpected_terminations = @($scm | Where-Object { $_.Id -in 7031, 7034 }).Count
    state_changes = @($scm | Where-Object Id -eq 7036).Count
    details = @($scm | Where-Object { $_.Id -in 7031, 7034 } | ForEach-Object { "$($_.TimeCreated.ToString('s')) $($_.Id) $($_.Message.Split("`n")[0])" }) }
$restartExits = 0
foreach ($w in 'portfolio-erp-worker-short', 'portfolio-erp-worker-long') {
    $restartExits += @(Select-String -Path "C:\srv\portfolio\erp\runtime\logs\$w\*.out*.log" -Pattern 'worker_win: work loop ended' -ErrorAction SilentlyContinue |
            Where-Object { $_.Line -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d' -and ([datetime]$_.Line.Substring(0, 19)) -ge $From -and ([datetime]$_.Line.Substring(0, 19)) -le $To }).Count
}
$out['worker_restart_exits'] = $restartExits

# Live simulation progress in the window
if ($out.impact.erp_events) { $out['simulation'] = $out.impact.erp_events }

# Final integrity and replay
foreach ($c in 'integrity', 'replay-check') {
    $log = Join-Path $EvidenceDir ("stability-{0:yyyyMMdd-HHmm}-$c.log" -f $From)
    & $ctl frappe -LogFile $log -- portfolio-sim $c | Out-Null
    $out[$c] = [ordered]@{ exit = $LASTEXITCODE; log = $log }
}
$file = Join-Path $EvidenceDir ("stability-{0:yyyyMMdd-HHmm}.json" -f $From)
$out | ConvertTo-Json -Depth 8 | Set-Content $file -Encoding UTF8
$pass = $out.impact.pass -and $out.monitor.failing_runs -eq 0 -and $out.service_events.unexpected_terminations -eq 0 -and $out.integrity.exit -eq 0 -and $out.'replay-check'.exit -eq 0
Write-Host ("stability {0} -> {1} ({2} h): latency {3}; monitor failing runs {4}/{5}; unexpected service terminations {6}; worker restart exits {7}; integrity exit {8}; replay exit {9}; overall {10}" -f
    $out.from, $out.to, $out.hours, $(if ($out.impact.pass) { 'PASS' } else { 'FAIL' }), $out.monitor.failing_runs, $out.monitor.runs, $out.service_events.unexpected_terminations,
    $restartExits, $out.integrity.exit, $out.'replay-check'.exit, $(if ($pass) { 'PASS' } else { 'FAIL' }))
Write-Host "written: $file"
