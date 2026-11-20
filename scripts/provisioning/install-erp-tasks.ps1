<#
.SYNOPSIS
  Scheduled tasks for the native-Windows ERPNext installation (SYSTEM). Idempotent.

.DESCRIPTION
  Copies the scripts to C:\srv\portfolio\scripts (outside the repository, Administrators/SYSTEM only) and registers:
    Portfolio - ERP nightly backup     daily at -BackupAt (default 04:15, after the CRM 03:15 and POS 03:45 dumps):
                                       backup-erp.ps1 -DeepVerify (scratch-instance restore + the app's integrity checks)
    Portfolio - ERP impact watchdog    no trigger; started on demand for load/stability windows
                                       (watch-erp-impact.ps1, evidence under C:\srv\portfolio\erp\evidence\watch)
  -Remove unregisters both.
#>
[CmdletBinding()]
param(
    [string]$BackupAt = '04:15',
    [double]$WatchHours = 30,
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$dest = 'C:\srv\portfolio\scripts'
$backupTask = 'Portfolio - ERP nightly backup'; $watchTask = 'Portfolio - ERP impact watchdog'
if ($Remove) {
    foreach ($t in $backupTask, $watchTask) { if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $t -Confirm:$false; Write-Host "removed $t" } }
    return
}
New-Item -ItemType Directory -Force $dest, "$dest\maintenance", "$dest\verification" | Out-Null
# backup-erp.ps1 and watch-erp-impact.ps1 call erp-ctl.ps1 relative to themselves: keep the repo's folder layout.
Copy-Item (Join-Path $repo 'scripts\maintenance\backup-erp.ps1'), (Join-Path $repo 'scripts\maintenance\erp-ctl.ps1') "$dest\maintenance" -Force
Copy-Item (Join-Path $repo 'scripts\verification\watch-erp-impact.ps1') "$dest\verification" -Force

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$time = [datetime]::ParseExact($BackupAt, 'HH:mm', $null)
$trigger = New-ScheduledTaskTrigger -Daily -At ((Get-Date).Date.AddHours($time.Hour).AddMinutes($time.Minute))
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dest\maintenance\backup-erp.ps1`" -DeepVerify"
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 3) -StartWhenAvailable -MultipleInstances IgnoreNew -Priority 7
Register-ScheduledTask -TaskName $backupTask -Trigger $trigger -Action $action -Principal $principal -Settings $settings `
    -Description 'Elite Business Systems Portfolio: ERPNext database + files + site config backup, scratch-instance restore check with the app integrity checks, 14-day retention.' -Force | Out-Null

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dest\verification\watch-erp-impact.ps1`" -MaxHours $WatchHours"
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 7
Register-ScheduledTask -TaskName $watchTask -Action $action -Principal $principal -Settings $settings `
    -Description 'Elite Business Systems Portfolio: ERP production-impact watchdog (on demand; pauses the ERP simulation on degradation).' -Force | Out-Null
foreach ($t in $backupTask, $watchTask) { $i = Get-ScheduledTask -TaskName $t | Get-ScheduledTaskInfo; Write-Host "registered '$t'; next run $($i.NextRunTime)" }
