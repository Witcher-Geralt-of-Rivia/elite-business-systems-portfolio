<#
.SYNOPSIS
  Publishes the POS (NexoPOS) at https://pos.<PUBLIC_IP>.sslip.io through the existing host Caddy — ONLY with
  -OwnerApproved (checkpoint decision POS-PUBLIC). -Rollback returns to the loopback-only site.

.DESCRIPTION
  1. Preflight (aborts without changing anything on failure): services running, production .env
     (APP_ENV=production, APP_DEBUG=false, secure cookies, session/sanctum domain = public host),
     visitor mode enabled, all hp:integrity checks passing.
  2. Fresh database backup with restore check (scripts/maintenance/backup-pos.ps1 -VerifyRestore).
  3. Writes the host-side approval flag C:\srv\portfolio\caddy\pos.public-enabled and runs
     render-caddy-sites.ps1 (caddy validate, then graceful reload; restores on validation failure).
  4. Public smoke checks (TLS certificate, security headers, hidden files, sign-in, visitor entry) and the
     visitor browser suite against the public URL. Any failure removes the flag and re-renders (rollback).
#>
[CmdletBinding()]
param(
    [string]$PublicIp = $env:PUBLIC_IP,
    [switch]$OwnerApproved,
    [switch]$Rollback,
    [switch]$SkipBrowserTests
)
$ErrorActionPreference = 'Stop'
if (-not $PublicIp -or $PublicIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw 'PublicIp is required (parameter or $env:PUBLIC_IP).' }
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$hostName = "pos.$PublicIp.sslip.io"
$flag = 'C:\srv\portfolio\caddy\pos.public-enabled'
$app = 'C:\srv\portfolio\pos\app'
$php = 'C:\srv\portfolio\pos\php\php.exe'
$render = Join-Path $PSScriptRoot 'render-caddy-sites.ps1'

function Disable-Public([string]$why) {
    Write-Warning "rolling back: $why"
    Remove-Item $flag -ErrorAction SilentlyContinue
    & $render -PublicIp $PublicIp
    # Portal back to "being finalised" (config.js, no /status/pos route).
    try { & (Join-Path $PSScriptRoot 'deploy-portal.ps1') -PublicIp $PublicIp } catch { Write-Warning "portal refresh failed: $_" }
    Write-Host 'POS is loopback-only again.'
}

if ($Rollback) { Disable-Public 'requested'; return }
if (-not $OwnerApproved) { throw 'Refusing: public POS access needs explicit owner approval (-OwnerApproved, decision POS-PUBLIC).' }

# ---- 1. preflight
Write-Host '== preflight'
foreach ($svc in 'portfolio-pos-mariadb', 'portfolio-pos-php-1', 'portfolio-pos-php-2', 'caddy') {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if (-not $s -or $s.Status -ne 'Running') { throw "service $svc is not running" }
}
$envFile = Get-Content (Join-Path $app '.env')
$expect = @{ APP_ENV = 'production'; APP_DEBUG = 'false'; SESSION_SECURE_COOKIE = 'true'; SESSION_DOMAIN = $hostName; SANCTUM_STATEFUL_DOMAINS = $hostName; APP_URL = "https://$hostName" }
foreach ($k in $expect.Keys) {
    $line = $envFile | Where-Object { $_ -match "^$k=" } | Select-Object -First 1
    $v = if ($line) { ($line -split '=', 2)[1].Trim('"') } else { '' }
    if ($v -ne $expect[$k]) { throw ".env $k is '$v', expected '$($expect[$k])'" }
}
Push-Location $app
try {
    $ErrorActionPreference = 'Continue'
    $integrity = (& $php artisan hp:integrity --json 2>$null) -join "`n" | ConvertFrom-Json
    $secret = Get-Content 'C:\srv\portfolio\secrets\pos-mariadb.json' -Raw | ConvertFrom-Json
    $env:MYSQL_PWD = $secret.app_password
    $showcase = (& 'C:\srv\portfolio\pos\mariadb\bin\mariadb.exe' -u $secret.app_user -h 127.0.0.1 -P "$($secret.port)" --protocol=TCP -N -B $secret.database `
        -e "SELECT value FROM nexopos_options WHERE ``key`` = 'harborpine_showcase'" 2>$null | Select-Object -First 1)
    Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
    $ErrorActionPreference = 'Stop'
} finally { Pop-Location }
$failing = @($integrity.failing.PSObject.Properties).Count
if ($failing -ne 0) { throw "integrity: $failing failing checks" }
Write-Host "  integrity: $($integrity.checks) checks pass"
if ("$showcase".Trim() -ne 'yes') { throw "visitor mode is not enabled (hp:showcase enable)" }

# ---- 2. backup
Write-Host '== backup'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\maintenance\backup-pos.ps1') -VerifyRestore
if ($LASTEXITCODE -ne 0) { throw 'backup failed; nothing changed' }

# ---- 3. publish
Write-Host '== publish'
Set-Content -Path $flag -Value "approved $(Get-Date -Format o)" -Encoding ascii
try { & $render -PublicIp $PublicIp } catch { Disable-Public "render failed: $_"; throw }

# ---- 4. smoke checks
Write-Host '== smoke checks'
try {
    $ok = $false
    for ($i = 0; $i -lt 30 -and -not $ok; $i++) {   # first request may wait for the certificate
        try { $r = Invoke-WebRequest -UseBasicParsing "https://$hostName/sign-in" -TimeoutSec 60; $ok = $r.StatusCode -eq 200 } catch { Start-Sleep -Seconds 5 }
    }
    if (-not $ok) { throw 'sign-in page not reachable over HTTPS' }
    if (-not $r.Headers['Strict-Transport-Security']) { throw 'HSTS header missing' }
    if ($r.Content -notmatch 'hp-showcase-entry') { throw 'visitor entry missing on sign-in page' }
    if (($r.Headers['Set-Cookie'] -join ';') -notmatch 'secure') { throw 'session cookie is not Secure' }
    foreach ($hidden in '/.env', '/../.env', '/storage/logs/laravel.log') {
        try { $h = Invoke-WebRequest -UseBasicParsing "https://$hostName$hidden" -TimeoutSec 30; if ($h.StatusCode -eq 200 -and $h.Content -match 'DB_PASSWORD|APP_KEY') { throw "exposed: $hidden" } } catch [System.Net.WebException] { }
    }
    try { Invoke-WebRequest -UseBasicParsing "http://$hostName/sign-in" -MaximumRedirection 0 -TimeoutSec 30 | Out-Null } catch [System.Net.WebException] { }
    Write-Host '  HTTPS, HSTS, secure cookie, visitor entry, hidden files: OK'
    if (-not $SkipBrowserTests) {
        & (Join-Path $repo 'scripts\verification\run-pos-e2e.ps1') -Mode visitor -BaseUrl "https://$hostName"
        if ($LASTEXITCODE -ne 0) { throw 'public visitor browser suite failed' }
    }
} catch {
    Disable-Public "$_"
    throw
}
# Portal: POS marked live (config.js) and its same-origin /status/pos route enabled (template @if-flag).
try { & (Join-Path $PSScriptRoot 'deploy-portal.ps1') -PublicIp $PublicIp } catch { Write-Warning "portal refresh failed (POS stays public): $_" }
Write-Host "POS is public at https://$hostName (visitor entry: /showcase/enter)."
