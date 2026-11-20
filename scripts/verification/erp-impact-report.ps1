<#
.SYNOPSIS
  Summarises the ERP watchdog samples for a time window: production latency vs the idle baseline and resources.

.DESCRIPTION
  Reads every watch-*.csv under -EvidenceDir, keeps the rows between -From and -To, and reports per production
  endpoint (CRM, portal, POS, co-hosted application) the median and 90th percentile latency, the ratio of the median
  to the baseline and PASS/FAIL against -LimitRatio (1.25 = at most 25 % slower); plus host CPU, available memory,
  commit, ERP CPU and ERP memory (median / max), and the ERP health codes seen. Output: a table and, with -Json,
  a JSON file for the evidence.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][datetime]$From,
    [Parameter(Mandatory)][datetime]$To,
    [string]$Label = 'window',
    [string]$EvidenceDir = 'C:\srv\portfolio\erp\evidence\watch',
    [string]$BaselineFile = 'C:\srv\portfolio\erp\evidence\watch\baseline.json',
    [double]$LimitRatio = 1.25,
    [string]$Json
)
$ErrorActionPreference = 'Stop'
$rows = foreach ($f in Get-ChildItem $EvidenceDir -Filter 'watch-*.csv') {
    # Read without locking the file the watchdog is appending to.
    $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
    $text = $sr.ReadToEnd(); $sr.Dispose()
    $text | ConvertFrom-Csv | Where-Object { $_.time -and ([datetime]$_.time) -ge $From -and ([datetime]$_.time) -le $To }
}
$rows = @($rows)
if (-not $rows) { throw "no samples between $From and $To" }
$base = Get-Content $BaselineFile -Raw | ConvertFrom-Json
function Q([double[]]$x, [double]$p) { $s = $x | Sort-Object; $s[[int][math]::Floor(($s.Count - 1) * $p)] }
$report = [ordered]@{ label = $Label; from = $From.ToString('s'); to = $To.ToString('s'); samples = $rows.Count; limit_ratio = $LimitRatio; endpoints = [ordered]@{} }
foreach ($ep in 'crm', 'portal', 'pos', 'cohosted') {
    $v = @($rows | ForEach-Object { [double]$_."${ep}_ms" } | Where-Object { $_ -gt 0 })
    if (-not $v) { continue }
    $med = Q $v 0.5; $ratio = [math]::Round($med / [double]$base.$ep, 2)
    $errCol = @($rows | Where-Object { $_.PSObject.Properties.Name -contains "${ep}_err" -and $_."${ep}_err" -ne '' } | ForEach-Object { [int]$_."${ep}_err" })
    $requests = 3 * $errCol.Count; $failed = ($errCol | Measure-Object -Sum).Sum
    $report.endpoints[$ep] = [ordered]@{ baseline_ms = [double]$base.$ep; median_ms = $med; p90_ms = (Q $v 0.9); p99_ms = (Q $v 0.99); ratio = $ratio
        requests = $requests; failed = [int]$failed; availability_pct = $(if ($requests) { [math]::Round(100 * ($requests - $failed) / $requests, 2) } else { $null })
        pass = ($ratio -le $LimitRatio -and -not $failed) }
}
$ev = @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'erp_events' -and $_.erp_events -match '^\d+$' })
if ($ev.Count -ge 2) {
    $dt = ([datetime]$ev[-1].time - [datetime]$ev[0].time).TotalSeconds; $de = [int]$ev[-1].erp_events - [int]$ev[0].erp_events
    $report['erp_events'] = [ordered]@{ first = [int]$ev[0].erp_events; last = [int]$ev[-1].erp_events; executed = $de; events_per_s = $(if ($dt -gt 0) { [math]::Round($de / $dt, 3) } else { 0 }) }
}
foreach ($m in @(@('host_cpu_pct', 'host_cpu'), @('avail_mb', 'available_mb'), @('commit_pct', 'commit'), @('erp_cpu_pct', 'erp_cpu'), @('erp_private_mb', 'erp_private_mb'), @('erp_disk_mb', 'erp_data_mb'),
        @('mariadb_ws_mb', 'mariadb_ws_mb'), @('redis_ws_mb', 'redis_ws_mb'), @('disk_free_gb', 'disk_free_gb'), @('disk_kb_s', 'disk_kb_s'))) {
    $v = @($rows | Where-Object { $_.PSObject.Properties.Name -contains $m[0] } | ForEach-Object { $_.($m[0]) } | Where-Object { $_ -ne '' -and $_ -ne $null } | ForEach-Object { [double]$_ })
    if ($v) { $report[$m[1]] = [ordered]@{ median = (Q $v 0.5); min = ($v | Measure-Object -Minimum).Minimum; max = ($v | Measure-Object -Maximum).Maximum } }
}
$report['erp_health_codes'] = ($rows | Group-Object erp_health | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ' '
$report['actions'] = @($rows | Where-Object { $_.action } | ForEach-Object { "$($_.time) $($_.action)" })
$report['pass'] = -not ($report.endpoints.Values | Where-Object { -not $_.pass })
Write-Host "$Label  $($report.from) -> $($report.to)  samples $($rows.Count)"
foreach ($ep in $report.endpoints.Keys) { $e = $report.endpoints[$ep]; Write-Host ("  {0,-9} baseline {1,5} ms  median {2,5} ms  p90 {3,5} ms  p99 {4,5} ms  ratio {5,5}  failed {6}/{7}  {8}" -f $ep, $e.baseline_ms, $e.median_ms, $e.p90_ms, $e.p99_ms, $e.ratio, $e.failed, $e.requests, $(if ($e.pass) { 'PASS' } else { 'FAIL' })) }
if ($report.Contains('erp_events')) { Write-Host ("  erp events      {0} -> {1}: {2} executed, {3} events/s" -f $report.erp_events.first, $report.erp_events.last, $report.erp_events.executed, $report.erp_events.events_per_s) }
foreach ($k in 'host_cpu', 'available_mb', 'commit', 'erp_cpu', 'erp_private_mb', 'erp_data_mb', 'mariadb_ws_mb', 'redis_ws_mb', 'disk_free_gb', 'disk_kb_s') { if ($report.Contains($k)) { Write-Host ("  {0,-15} median {1,8}  min {2,8}  max {3,8}" -f $k, $report[$k].median, $report[$k].min, $report[$k].max) } }
Write-Host "  erp health: $($report.erp_health_codes); watchdog actions: $($report.actions.Count); overall: $(if ($report.pass) { 'PASS' } else { 'FAIL' })"
if ($Json) { $report | ConvertTo-Json -Depth 5 | Set-Content $Json -Encoding UTF8 }
