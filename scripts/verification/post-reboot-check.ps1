<#
.SYNOPSIS
  Post-reboot recovery checklist (ERP WSL1 PoC stage S1 pass criterion). Read-only; safe to run repeatedly.

.DESCRIPTION
  Pass criterion of S1: within 10 minutes of boot, everything below passes. It reports each check and exits 1 if
  any fails; re-run until it passes or the 10 minutes are over (then follow the runbook's rollback).
    - every service of Release 1.0, the co-hosted application and remote access is Running;
    - health monitor: a fresh run with all checks OK (public CRM/POS/portal health, TLS, services, backups, disk);
    - POS: simulation caught up (lag < 15 min unless paused), hp:integrity all 0, no duplicate ledger keys;
    - CRM: simulation integrity 0 failing;
    - co-hosted application reachable over HTTPS (any 2xx/3xx);
    - host Caddyfile unchanged (SHA-256 given with -CaddyfileSha256);
    - optional features: WSL as expected (-ExpectWsl Enabled after S1), VirtualMachinePlatform / Hyper-V Disabled.
#>
[CmdletBinding()]
param(
    [ValidateSet('Enabled', 'Disabled')] [string]$ExpectWsl = 'Enabled',
    [string]$CaddyfileSha256,
    [string]$PublicIp = $env:PUBLIC_IP
)
$ErrorActionPreference = 'Continue'
if (-not $PublicIp) { $PublicIp = (Select-String -Path C:\srv\portfolio\caddy\crm.caddy -Pattern 'crm\.(\d+\.\d+\.\d+\.\d+)\.sslip').Matches[0].Groups[1].Value }
$fail = 0
function Report([string]$name, [bool]$ok, [string]$detail) {
    if (-not $ok) { $script:fail++ }
    Write-Host ("[{0}] {1}: {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, ($detail -replace [regex]::Escape($PublicIp), '<VPS_IP>')) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}

$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
Write-Host "last boot: $boot ($([math]::Round(((Get-Date) - $boot).TotalMinutes, 1)) min ago)"
$names = 'caddy', 'portfolio-crm-postgres', 'portfolio-crm-api', 'portfolio-pos-mariadb', 'portfolio-pos-php-1', 'portfolio-pos-php-2',
    'portfolio-pos-sim', 'sshd', 'RustDesk', 'AnyDesk', 'JumpConnect', 'TermService'
# The co-hosted application's identifiers live only on the host, not in this public repository.
$coCfg = if (Test-Path 'C:\srv\portfolio\config\cohosted.json') { Get-Content 'C:\srv\portfolio\config\cohosted.json' -Raw | ConvertFrom-Json } else { $null }
if ($coCfg) { $names += @(Get-Service | Where-Object { $n = $_.Name; @($coCfg.service_patterns | Where-Object { $n -like $_ }).Count } | ForEach-Object Name) }
else { Report 'co-hosted configuration' $false 'C:\srv\portfolio\config\cohosted.json missing' }
foreach ($n in $names) {
    $s = Get-Service $n -ErrorAction SilentlyContinue
    Report "service $n" ($s -and $s.Status -eq 'Running') $(if ($s) { "$($s.Status)" } else { 'missing' })
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\srv\portfolio\scripts\monitor-portfolio.ps1' | Out-Null
$m = Get-Content ("C:\srv\portfolio\logs\monitor-{0:yyyyMM}.jsonl" -f (Get-Date)) -Tail 1 | ConvertFrom-Json
Report 'health monitor' ([bool]$m.ok) "failing: $($m.failing -join ', ')"

$h = (& curl.exe -s -m 30 "https://pos.$PublicIp.sslip.io/harborpine/health") -join '' | ConvertFrom-Json
Report 'POS simulation caught up' ($h.status -eq 'ok' -and ($h.simulation.paused -or $h.simulation.lag_seconds -lt 900)) "lag $($h.simulation.lag_seconds)s, worker_running=$($h.simulation.worker_running)"
Push-Location C:\srv\portfolio\pos\app
try {
    $i = (& C:\srv\portfolio\pos\php\php.exe artisan hp:integrity --json 2>$null) -join "`n" | ConvertFrom-Json
    Report 'POS integrity' ($i.checks -ge 43 -and $i.failing -is [array]) "$($i.checks) checks"
} finally { Pop-Location }
$s = Get-Content C:\srv\portfolio\secrets\pos-mariadb.json -Raw | ConvertFrom-Json
$env:MYSQL_PWD = $s.app_password
$dups = (& C:\srv\portfolio\pos\mariadb\bin\mariadb.exe -u $s.app_user -h 127.0.0.1 -P "$($s.port)" --protocol=TCP -N $s.database `
    -e "select count(*) from (select event_key from harborpine_sim_ledger group by event_key having count(*) > 1) x" 2>$null) -join ''
Remove-Item Env:MYSQL_PWD
Report 'POS ledger duplicates' ($dups.Trim() -eq '0') "duplicate keys: $dups"

$keys = @()
Get-Content C:\srv\portfolio\secrets\crm-api.env | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; Set-Item "Env:$k" $v.Trim('"'); $keys += $k }
Push-Location C:\srv\portfolio\crm\api
try {
    $out = (node scripts/simulate.ts integrity 2>$null) -join "`n"
    $c = $out.Substring($out.IndexOf('{')) | ConvertFrom-Json
    Report 'CRM integrity' ($c.checks -ge 22 -and @($c.failing).Count -eq 0) "$($c.checks) checks"
} catch { Report 'CRM integrity' $false "$_" } finally { Pop-Location; $keys | ForEach-Object { Remove-Item "Env:$_" -ErrorAction SilentlyContinue } }

if ($coCfg -and $coCfg.url) {
    $code = & curl.exe -s -m 30 -o NUL -w '%{http_code}' $coCfg.url
    Report 'co-hosted application reachable' ($code -match '^[23]') "HTTP $code"
}

if ($CaddyfileSha256) {
    $hash = (Get-FileHash C:\srv\caddy\Caddyfile -Algorithm SHA256).Hash
    Report 'host Caddyfile unchanged' ($hash -eq $CaddyfileSha256.ToUpper()) $hash.Substring(0, 12)
}
$wsl = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux).State
Report 'WSL feature' ("$wsl" -eq $ExpectWsl) "$wsl (expected $ExpectWsl)"
foreach ($f in 'VirtualMachinePlatform', 'Microsoft-Hyper-V', 'HypervisorPlatform') {
    $st = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue).State
    Report "feature $f stays off (WSL1 only)" ("$st" -ne 'Enabled') "$st"
}
Write-Host "post-reboot check: $fail failing"
if ($fail) { exit 1 }
