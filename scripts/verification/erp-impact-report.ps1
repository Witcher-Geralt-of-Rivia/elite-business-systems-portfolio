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
    $report.endpoints[$ep] = [ordered]@{ baseline_ms = [double]$base.$ep; median_ms = $med; p90_ms = (Q $v 0.9); ratio = $ratio; pass = ($ratio -le $LimitRatio) }
}
foreach ($m in @(@('host_cpu_pct', 'host_cpu'), @('avail_mb', 'available_mb'), @('commit_pct', 'commit'), @('erp_cpu_pct', 'erp_cpu'), @('erp_private_mb', 'erp_private_mb'), @('erp_disk_mb', 'erp_data_mb'))) {
    $v = @($rows | ForEach-Object { $_.($m[0]) } | Where-Object { $_ -ne '' } | ForEach-Object { [double]$_ })
    if ($v) { $report[$m[1]] = [ordered]@{ median = (Q $v 0.5); min = ($v | Measure-Object -Minimum).Minimum; max = ($v | Measure-Object -Maximum).Maximum } }
}
$report['erp_health_codes'] = ($rows | Group-Object erp_health | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ' '
$report['actions'] = @($rows | Where-Object { $_.action } | ForEach-Object { "$($_.time) $($_.action)" })
$report['pass'] = -not ($report.endpoints.Values | Where-Object { -not $_.pass })
Write-Host "$Label  $($report.from) -> $($report.to)  samples $($rows.Count)"
foreach ($ep in $report.endpoints.Keys) { $e = $report.endpoints[$ep]; Write-Host ("  {0,-9} baseline {1,5} ms  median {2,5} ms  p90 {3,5} ms  ratio {4,5}  {5}" -f $ep, $e.baseline_ms, $e.median_ms, $e.p90_ms, $e.ratio, $(if ($e.pass) { 'PASS' } else { 'FAIL' })) }
foreach ($k in 'host_cpu', 'available_mb', 'commit', 'erp_cpu', 'erp_private_mb', 'erp_data_mb') { if ($report.Contains($k)) { Write-Host ("  {0,-15} median {1,8}  min {2,8}  max {3,8}" -f $k, $report[$k].median, $report[$k].min, $report[$k].max) } }
Write-Host "  erp health: $($report.erp_health_codes); watchdog actions: $($report.actions.Count); overall: $(if ($report.pass) { 'PASS' } else { 'FAIL' })"
if ($Json) { $report | ConvertTo-Json -Depth 5 | Set-Content $Json -Encoding UTF8 }
