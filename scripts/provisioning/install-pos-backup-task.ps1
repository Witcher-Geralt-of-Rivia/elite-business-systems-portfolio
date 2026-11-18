<#
.SYNOPSIS
  Installs the nightly POS database backup (with restore check) as a SYSTEM scheduled task.

.DESCRIPTION
  Copies scripts/maintenance/backup-pos.ps1 to C:\srv\portfolio\scripts (outside the repo, Administrators/
  SYSTEM only) and registers "Portfolio - POS nightly backup" daily at -At (default 03:45, after the CRM
  backup at 03:15 so the two dumps never overlap). -StartDate delays the first run. Idempotent.
#>
[CmdletBinding()]
param(
    [string]$At = '03:45',
    [datetime]$StartDate = (Get-Date).Date
)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$dest = 'C:\srv\portfolio\scripts'
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $repo 'scripts\maintenance\backup-pos.ps1') (Join-Path $dest 'backup-pos.ps1') -Force

$name = 'Portfolio - POS nightly backup'
$time = [datetime]::ParseExact($At, 'HH:mm', $null)
$trigger = New-ScheduledTaskTrigger -Daily -At ($StartDate.Date.AddHours($time.Hour).AddMinutes($time.Minute))
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dest\backup-pos.ps1`" -VerifyRestore"
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $name -Trigger $trigger -Action $action -Principal $principal -Settings $settings `
    -Description 'Elite Business Systems Portfolio: NexoPOS MariaDB dump + sha256 + restore check, 14-day retention.' -Force | Out-Null
$info = Get-ScheduledTask -TaskName $name | Get-ScheduledTaskInfo
Write-Host "registered '$name'; next run $($info.NextRunTime)"
