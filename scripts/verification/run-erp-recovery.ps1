<#
.SYNOPSIS
  Recovery test for the native-Windows ERPNext services: unexpected process termination and graceful stop/start.

.DESCRIPTION
  For each service in -Services (default: all nine), the real process (the child of the WinSW wrapper, or mariadbd)
  is terminated with Stop-Process -Force, as a crash would. The test then measures:
    restart_s   until the service runs a NEW process again (the service manager's restart-on-failure action)
    healthy_s   until GET /api/method/portfolio_sim.health.status returns 200 with every component ok
  With -Graceful it also stops the whole ERP stack in dependency order (erp-ctl.ps1 stop), starts it again and
  measures time to healthy. Results: <EvidenceDir>\recovery-<time>.json. CRM, POS and the co-hosted application are
  not touched. Note: restart delays escalate (10 s, 30 s, 60 s) when one service fails repeatedly within an hour.
#>
[CmdletBinding()]
param(
    [string[]]$Services = @('portfolio-erp-redis-cache', 'portfolio-erp-redis-queue', 'portfolio-erp-web', 'portfolio-erp-worker-short',
        'portfolio-erp-worker-long', 'portfolio-erp-scheduler', 'portfolio-erp-socketio', 'portfolio-erp-proxy', 'portfolio-erp-mariadb'),
    [switch]$Graceful,
    [int]$TimeoutSec = 300,
    [string]$EvidenceDir = 'C:\srv\portfolio\erp\evidence\native'
)
$ErrorActionPreference = 'Stop'
$ctl = Join-Path $PSScriptRoot '..\maintenance\erp-ctl.ps1'
New-Item -ItemType Directory -Force $EvidenceDir | Out-Null

function Get-Health {
    $out = & curl.exe -s -m 20 -w "`n%{http_code}" 'http://127.0.0.1:8850/api/method/portfolio_sim.health.status' 2>$null
    $lines = @($out); $code = $lines[-1]
    try { $h = (($lines | Select-Object -SkipLast 1) -join "`n" | ConvertFrom-Json).message } catch { $h = $null }
    return [pscustomobject]@{ ok = ($code -eq '200' -and $h.ok); code = $code; body = $h }
}
function Get-WorkProcess([string]$svc) {
    $w = Get-CimInstance Win32_Service -Filter "Name='$svc'"
    if (-not $w -or -not $w.ProcessId) { return $null }
    if ($svc -eq 'portfolio-erp-mariadb') { return [int]$w.ProcessId }   # native service: the server itself
    $child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($w.ProcessId)" | Where-Object Name -notlike 'conhost*' | Select-Object -First 1
    if ($child) { return [int]$child.ProcessId } else { return $null }
}
function Wait-Healthy([datetime]$since) {
    while (((Get-Date) - $since).TotalSeconds -lt $TimeoutSec) {
        if ((Get-Health).ok) { return [math]::Round(((Get-Date) - $since).TotalSeconds, 1) }
        Start-Sleep -Seconds 2
    }
    return $null
}

if (-not (Get-Health).ok) { throw 'ERP is not healthy before the test; aborting' }
$results = @()
foreach ($svc in $Services) {
    $old = Get-WorkProcess $svc
    if (-not $old) { $results += [pscustomobject]@{ service = $svc; result = 'no process' }; continue }
    $t0 = Get-Date
    Stop-Process -Id $old -Force
    $restart = $null
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        $new = Get-WorkProcess $svc
        if ($new -and $new -ne $old -and (Get-Service $svc).Status -eq 'Running') { $restart = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1); break }
        Start-Sleep -Milliseconds 500
    }
    $healthy = Wait-Healthy $t0
    $r = [pscustomobject]@{ service = $svc; killed_pid = $old; new_pid = $new; restart_s = $restart; healthy_s = $healthy
        result = if ($restart -and $healthy) { 'recovered' } else { 'FAILED' } }
    $results += $r
    Write-Host ("{0,-28} killed {1,6} -> {2,6}  restart {3,6} s  healthy {4,6} s  {5}" -f $svc, $old, $new, $restart, $healthy, $r.result)
    Start-Sleep -Seconds 15   # let workers re-register and the scheduler tick before the next kill
}
if ($Graceful) {
    $t0 = Get-Date; & $ctl stop | Out-Null; $stopS = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    $leftover = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like 'C:\srv\portfolio\erp\runtime\*' -or $_.CommandLine -match 'realtime_win' })
    $t1 = Get-Date; & $ctl start | Out-Null; $healthy = Wait-Healthy $t1
    $results += [pscustomobject]@{ service = 'all (graceful stop/start)'; stop_s = $stopS; leftover_processes = $leftover.Count; healthy_s = $healthy
        result = if ($healthy -and $leftover.Count -eq 0) { 'recovered' } else { 'FAILED' } }
    Write-Host "graceful: stop $stopS s, leftover processes $($leftover.Count), healthy after start $healthy s"
}
$file = Join-Path $EvidenceDir ("recovery-{0:yyyyMMdd-HHmm}.json" -f (Get-Date))
$results | ConvertTo-Json -Depth 4 | Set-Content $file -Encoding UTF8
Write-Host "results: $file"
if ($results | Where-Object result -ne 'recovered') { exit 1 }
