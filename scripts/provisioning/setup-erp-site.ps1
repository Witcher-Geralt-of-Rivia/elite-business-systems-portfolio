<#
.SYNOPSIS
  Creates a Frappe site with ERPNext and portfolio_sim on the native-Windows runtime. Idempotent per step.

.DESCRIPTION
  -Site erp.portfolio.local (default): the private production site served by the proxy.
  -Site <name> -Test: a separate site for the integration tests (allow_tests on, own database); never the proxy's site.
  Steps: new-site with ERPNext (database user scoped to '%' - the server itself only listens on 127.0.0.1, and with
  skip-name-resolve a 'localhost' account would not match TCP connections), install portfolio_sim, enable the
  scheduler, host_name, ACL on site_config.json (Administrators/SYSTEM/LOCAL SERVICE only).
  Credentials come from C:\srv\portfolio\secrets\erp-runtime.json and are passed to the Frappe CLI only.
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\srv\portfolio\erp\runtime',
    [string]$Site = 'erp.portfolio.local',
    [switch]$Test,
    [string]$HostName = 'http://127.0.0.1:8850'
)
$ErrorActionPreference = 'Stop'
$ctl = Join-Path $PSScriptRoot '..\maintenance\erp-ctl.ps1'
$secret = Get-Content 'C:\srv\portfolio\secrets\erp-runtime.json' -Raw | ConvertFrom-Json
$siteDir = Join-Path $Root "bench\sites\$Site"
$logDir = Join-Path $Root 'logs\setup'
New-Item -ItemType Directory -Force $logDir | Out-Null
function Invoke-Frappe([string]$name, [switch]$NoSite, [string[]]$a) {
    $log = Join-Path $logDir "$Site-$name.log"
    $t = Get-Date
    if ($NoSite) { & $ctl frappe -Root $Root -NoSite -LogFile $log -- @a } else { & $ctl frappe -Root $Root -Site $Site -LogFile $log -- @a }
    $code = $LASTEXITCODE
    Write-Host ("  {0}: exit {1} in {2:N0} s" -f $name, $code, ((Get-Date) - $t).TotalSeconds)
    if ($code -ne 0) { Get-Content $log -Tail 25 | ForEach-Object { Write-Host "    $_" }; throw "$name failed" }
}

if (-not (Test-Path (Join-Path $siteDir 'site_config.json'))) {
    Invoke-Frappe 'new-site' -NoSite @('new-site', $Site, '--db-root-username', 'root', '--db-root-password', $secret.db_root_password,
        '--admin-password', $secret.admin_password, '--mariadb-user-host-login-scope=%', '--install-app', 'erpnext')
}
Invoke-Frappe 'list-apps-before' @('list-apps')
if ((Get-Content (Join-Path $logDir "$Site-list-apps-before.log") -Raw) -notmatch 'portfolio_sim') { Invoke-Frappe 'install-app' @('install-app', 'portfolio_sim') }
if ($Test) {
    Invoke-Frappe 'allow-tests' @('set-config', 'allow_tests', 'true')
} else {
    Invoke-Frappe 'host-name' @('set-config', 'host_name', $HostName)
    Invoke-Frappe 'enable-scheduler' @('enable-scheduler')
}
$cfg = Join-Path $siteDir 'site_config.json'
icacls $cfg /inheritance:r /grant 'BUILTIN\Administrators:(F)' 'NT AUTHORITY\SYSTEM:(F)' 'NT AUTHORITY\LOCAL SERVICE:(R)' | Out-Null
Invoke-Frappe 'list-apps' @('list-apps')
Get-Content (Join-Path $logDir "$Site-list-apps.log") | Where-Object { $_ -match '\S' -and $_ -notmatch 'stderr' } | ForEach-Object { Write-Host "  $_" }
Write-Host "site $Site ready"
