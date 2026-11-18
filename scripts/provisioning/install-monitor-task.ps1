<#
.SYNOPSIS
  Installs the read-only portfolio health monitor as a SYSTEM scheduled task (every 15 minutes).

.DESCRIPTION
  Copies scripts/maintenance/monitor-portfolio.ps1 to C:\srv\portfolio\scripts (Administrators/SYSTEM only),
  registers the Application event-log source "PortfolioMonitor" (once), and registers
  "Portfolio - health monitor" repeating every -EveryMinutes. Idempotent.
#>
[CmdletBinding()]
param([int]$EveryMinutes = 15)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$dest = 'C:\srv\portfolio\scripts'
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $repo 'scripts\maintenance\monitor-portfolio.ps1') (Join-Path $dest 'monitor-portfolio.ps1') -Force
if (-not [Diagnostics.EventLog]::SourceExists('PortfolioMonitor')) { New-EventLog -LogName Application -Source 'PortfolioMonitor' }

$name = 'Portfolio - health monitor'
$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dest\monitor-portfolio.ps1`""
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $name -Trigger $trigger -Action $action -Principal $principal -Settings $settings `
    -Description 'Elite Business Systems Portfolio: read-only health checks (public endpoints, POS worker, TLS, services, backups, disk); log + event log on state change.' -Force | Out-Null
$info = Get-ScheduledTask -TaskName $name | Get-ScheduledTaskInfo
Write-Host "registered '$name' every $EveryMinutes min; next run $($info.NextRunTime)"
