<#
.SYNOPSIS
  Pre-reboot gate (ERP WSL1 PoC stage S0). Read-only by default; -RunBackups takes fresh verified CRM and POS backups.

.DESCRIPTION
  Checks, each reported as PASS/FAIL/INFO, and writes a JSON report to C:\srv\portfolio\logs\preflight-<stamp>.json:
    - automatic start of the services that must come back after a reboot (Caddy, portfolio, co-hosted application,
      remote access);
    - all of them running now; Remote Desktop enabled;
    - Windows optional features: WSL Disabled (S1 enables only Microsoft-Windows-Subsystem-Linux);
      VirtualMachinePlatform, Hyper-V and HypervisorPlatform Disabled (must stay so: WSL1 only);
    - pending reboot state (servicing, Windows Update), plus a summary of queued file rename operations;
    - latest CRM and POS backups (age, .sha256) and nightly task results. With -RunBackups, new backups are taken with
      the restore check (the same scripts the nightly tasks run);
    - the co-hosted application's own daily backup task: last run and result only (read-only, never started here);
    - health monitor: a fresh run (all checks must be OK);
    - git checkpoint: clean working tree, local HEAD equals origin/main.
  The provider's out-of-band console cannot be verified from inside the VPS: the report lists it as an owner
  confirmation. Nothing is enabled, disabled, restarted or reconfigured.
#>
[CmdletBinding()]
param(
    [switch]$RunBackups,
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')),
    [int]$MaxBackupAgeHours = 26
)
$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()
function Add-Check([string]$area, [string]$name, [string]$status, [string]$detail) {
    $results.Add([pscustomobject]@{ area = $area; check = $name; status = $status; detail = $detail })
    $color = @{ PASS = 'Green'; FAIL = 'Red'; INFO = 'Yellow' }[$status]
    Write-Host ("[{0}] {1,-9} {2}: {3}" -f $status, $area, $name, $detail) -ForegroundColor $color
}

# Services that must start automatically after a reboot. The co-hosted application's identifiers live only on the
# host (C:\srv\portfolio\config\cohosted.json), not in this public repository.
$required = 'caddy', 'portfolio-crm-postgres', 'portfolio-crm-api', 'portfolio-pos-mariadb', 'portfolio-pos-php-1',
    'portfolio-pos-php-2', 'portfolio-pos-sim', 'sshd', 'RustDesk', 'AnyDesk', 'JumpConnect', 'Schedule'
$coCfg = if (Test-Path 'C:\srv\portfolio\config\cohosted.json') { Get-Content 'C:\srv\portfolio\config\cohosted.json' -Raw | ConvertFrom-Json } else { $null }
$cohosted = @(if ($coCfg) { Get-CimInstance Win32_Service | Where-Object { $n = $_.Name; @($coCfg.service_patterns | Where-Object { $n -like $_ }).Count } | ForEach-Object Name })
if (-not $coCfg) { Add-Check 'services' 'co-hosted application' 'INFO' 'C:\srv\portfolio\config\cohosted.json missing: co-hosted services not checked' }
foreach ($n in $required + $cohosted) {
    $s = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
    if (-not $s) { Add-Check 'services' $n 'FAIL' 'not installed'; continue }
    $ok = $s.StartMode -eq 'Auto' -and $s.State -eq 'Running'
    Add-Check 'services' $n $(if ($ok) { 'PASS' } else { 'FAIL' }) "start=$($s.StartMode) state=$($s.State)"
}
$rdp = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections -eq 0
Add-Check 'remote' 'Remote Desktop enabled' $(if ($rdp) { 'PASS' } else { 'FAIL' }) "fDenyTSConnections=$(if ($rdp) { 0 } else { 1 }); TermService is trigger-started"

# Optional features: WSL1 only.
foreach ($f in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform', 'Microsoft-Hyper-V', 'HypervisorPlatform') {
    $st = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue).State
    Add-Check 'features' $f $(if ($st -eq 'Disabled') { 'PASS' } else { 'FAIL' }) "$st (must be Disabled before S1; S1 enables only the WSL feature)"
}

# Pending reboot state.
$cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$wu = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
Add-Check 'reboot' 'servicing / Windows Update reboot pending' $(if ($cbs -or $wu) { 'INFO' } else { 'PASS' }) "CBS=$cbs WU=$wu"
$v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
if ($v) {
    $groups = @{}
    for ($i = 0; $i -lt $v.Count; $i += 2) {
        $src = $v[$i] -replace '^\*\d\\\?\?\\', '' -replace '^\\\?\?\\', ''
        $g = if ($src -match '(?i)\\spool\\V4Dirs\\') { 'print spooler driver cache (delete)' }
            elseif ($src -match '(?i)\\Windows\\(System32|SysWOW64|WinSxS)\\') { 'WINDOWS SYSTEM FILE' }
            else { (($src -split '\\')[0..2] -join '\') + $(if ($v[$i + 1]) { ' (rename)' } else { ' (delete)' }) }
        $groups[$g] = 1 + [int]$groups[$g]
    }
    $system = [int]$groups['WINDOWS SYSTEM FILE']
    Add-Check 'reboot' 'queued file operations' $(if ($system) { 'INFO' } else { 'PASS' }) (($groups.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Value)x $($_.Key)" }) -join '; ')
}

# Backups.
if ($RunBackups) {
    foreach ($b in 'backup-crm.ps1', 'backup-pos.ps1') {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo "scripts\maintenance\$b") -VerifyRestore | Out-Host
        Add-Check 'backup' "$b -VerifyRestore (fresh)" $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) "exit $LASTEXITCODE"
    }
}
foreach ($b in @(@{ app = 'crm'; filter = 'crm-*.dump' }, @{ app = 'pos'; filter = 'pos-*.sql' })) {
    $latest = Get-ChildItem "C:\srv\portfolio\backups\$($b.app)" -Filter $b.filter -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $age = if ($latest) { [math]::Round(((Get-Date) - $latest.LastWriteTime).TotalHours, 1) } else { 9999 }
    $sha = $latest -and (Test-Path "$($latest.FullName).sha256")
    Add-Check 'backup' "$($b.app) latest" $(if ($age -le $MaxBackupAgeHours -and $sha) { 'PASS' } else { 'FAIL' }) "$($latest.Name) $age h old, sha256=$sha"
}
foreach ($t in Get-ScheduledTask | Where-Object { $_.TaskName -like 'Portfolio - * backup' -or ($coCfg -and $_.TaskName -like $coCfg.backup_task_pattern) }) {
    $i = $t | Get-ScheduledTaskInfo
    $age = [math]::Round(((Get-Date) - $i.LastRunTime).TotalHours, 1)
    Add-Check 'backup' "task $($t.TaskName)" $(if ($i.LastTaskResult -eq 0 -and $age -le $MaxBackupAgeHours) { 'PASS' } else { 'FAIL' }) "last run $($i.LastRunTime) ($age h), result $($i.LastTaskResult)"
}

# Monitoring.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\srv\portfolio\scripts\monitor-portfolio.ps1' | Out-Null
$last = Get-Content ("C:\srv\portfolio\logs\monitor-{0:yyyyMM}.jsonl" -f (Get-Date)) -Tail 1 | ConvertFrom-Json
Add-Check 'monitor' 'health monitor run' $(if ($last.ok) { 'PASS' } else { 'FAIL' }) "$(@($last.checks.PSObject.Properties).Count) checks; failing: $($last.failing -join ', ')"

# Git checkpoint.
Push-Location $Repo
try {
    $ErrorActionPreference = 'Continue'
    git fetch -q origin 2>$null
    $dirty = @(git status --porcelain).Count
    $head = (git rev-parse HEAD).Trim(); $remote = (git rev-parse origin/main).Trim()
    Add-Check 'git' 'checkpoint clean and pushed' $(if ($dirty -eq 0 -and $head -eq $remote) { 'PASS' } else { 'FAIL' }) "dirty=$dirty head=$($head.Substring(0,7)) origin=$($remote.Substring(0,7))"
} finally { Pop-Location }

Add-Check 'owner' 'provider out-of-band console' 'INFO' 'cannot be verified from inside the VPS: owner must confirm access before S1'
Add-Check 'owner' 'maintenance window and REBOOT approval' 'INFO' 'required before S1'

$report = [pscustomobject]@{ time = (Get-Date).ToString('o'); fail = @($results | Where-Object status -eq 'FAIL').Count; results = $results }
$out = "C:\srv\portfolio\logs\preflight-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date)
$report | ConvertTo-Json -Depth 4 | Set-Content $out -Encoding UTF8
Write-Host "preflight: $($report.fail) failing check(s); report $out"
if ($report.fail) { exit 1 }
