<#
.SYNOPSIS
  Controlled ERP performance benchmark in three phases, recorded against the impact watchdog's samples.

.DESCRIPTION
  A  ERP services running, no backfill (-IdleMinutes)
  B  history backfill alone (BELOW NORMAL priority) with the site scheduler disabled, so no ERPNext background jobs
     compete (`frappe disable-scheduler`); continues the deterministic history up to -UntilB
  C  backfill with the scheduler enabled and the normal background workers active, up to -UntilC
  Phase boundaries go to <EvidenceDir>\benchmark-<stamp>.json; the latency/resource analysis comes from
  erp-impact-report.ps1 over each phase window (the watchdog keeps sampling and keeps its shedding rule: if it
  stops the backfill, the phase ends early and is recorded as such). No browser tests run during the benchmark.
  The backfill is idempotent continuation: nothing is reset or re-generated.
#>
[CmdletBinding()]
param(
    [int]$IdleMinutes = 20,
    [string]$UntilB = '2025-09-15T23:59:59',
    [string]$UntilC = '2025-10-31T23:59:59',
    [string]$EvidenceDir = 'C:\srv\portfolio\erp\evidence\native'
)
$ErrorActionPreference = 'Stop'
$ctl = Join-Path $PSScriptRoot '..\maintenance\erp-ctl.ps1'
$report = Join-Path $PSScriptRoot 'erp-impact-report.ps1'
$stamp = Get-Date -Format yyyyMMdd-HHmm
$out = Join-Path $EvidenceDir "benchmark-$stamp.json"
$phases = [ordered]@{}
function Save { $phases | ConvertTo-Json -Depth 6 | Set-Content $out -Encoding UTF8 }
function Frappe([string]$log, [string[]]$a) { & $ctl frappe -LogFile (Join-Path $EvidenceDir $log) -- @a; return $LASTEXITCODE }

# A - idle
$t0 = Get-Date
Start-Sleep -Seconds ($IdleMinutes * 60)
$phases['A_idle'] = [ordered]@{ from = $t0.ToString('s'); to = (Get-Date).ToString('s') }; Save

# B - backfill alone, scheduler disabled
Frappe 'bench-disable-scheduler.log' @('disable-scheduler') | Out-Null
$t1 = Get-Date
$codeB = Frappe 'bench-backfill-B.log' @('portfolio-sim', 'backfill', '--until', $UntilB)
$phases['B_backfill_alone'] = [ordered]@{ from = $t1.ToString('s'); to = (Get-Date).ToString('s'); until = $UntilB; exit = $codeB }
Frappe 'bench-enable-scheduler.log' @('enable-scheduler') | Out-Null
Save

# C - backfill with scheduler and workers
$t2 = Get-Date
$codeC = if ($codeB -eq 0) { Frappe 'bench-backfill-C.log' @('portfolio-sim', 'backfill', '--until', $UntilC) } else { 'skipped (B failed)' }
$phases['C_backfill_with_scheduler'] = [ordered]@{ from = $t2.ToString('s'); to = (Get-Date).ToString('s'); until = $UntilC; exit = $codeC }
Save

foreach ($k in @($phases.Keys)) {
    $j = Join-Path $EvidenceDir "benchmark-$stamp-$k.json"
    try { & $report -From ([datetime]$phases[$k].from) -To ([datetime]$phases[$k].to) -Label $k -Json $j | Out-Null; $phases[$k]['report'] = $j } catch { $phases[$k]['report'] = "error: $_" }
}
Save
Write-Host "benchmark written to $out"
