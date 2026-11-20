<#
.SYNOPSIS
  Publishes ERPNext at https://erp.<PUBLIC_IP>.sslip.io through the existing host Caddy - ONLY with -OwnerApproved
  (owner decision ERP-PUBLIC, not given as of 2026-11-20). -Rollback returns to private (loopback-only) operation.

.DESCRIPTION
  1. Preflight (aborts without changing anything on failure): all 9 ERP services running, health 200, no ERP listener
     outside 127.0.0.1, verified assets installed, `portfolio-sim integrity` and `replay-check` pass, the nightly
     backup task's last result 0.
  2. Visitor role/user (portfolio-sim visitor-setup) and production authentication settings
     (portfolio-sim public-settings: login throttling, password policy, session expiry, no sign-up, Administrator and
     the test user restricted to 127.0.0.1).
  3. Fresh backup with restore check (backup-erp.ps1 -VerifyRestore).
  4. Site config: host_name https://erp.<ip>.sslip.io, portfolio_visitor_enabled 1. Host-side approval flag
     C:\srv\portfolio\caddy\erp.public-enabled; ERP site file C:\srv\portfolio\caddy\erp.caddy from
     infrastructure/proxy/sites-inactive/erp-public.caddy.disabled; whole host Caddyfile validated, graceful reload
     (never a restart).
  5. Public checks (TLS certificate, HSTS and other headers, Secure session cookie, /login, visitor entry, internal
     endpoints 404) and the browser suite (visitor + guest specs) against the public URL. Any failure -> rollback.
  6. Portal: ERP marked live and /status/erp enabled (deploy-portal.ps1).
  Rollback: removes erp.caddy and the flag, reloads Caddy, turns visitor access off, host_name back to the loopback
  URL, redeploys the portal ("in preparation"). CRM, POS, the co-hosted application and their configuration are
  never touched.
#>
[CmdletBinding()]
param(
    [string]$PublicIp = $env:PUBLIC_IP,
    [switch]$OwnerApproved,
    [switch]$Rollback,
    [switch]$SkipBrowserTests,
    [string]$CaddyExe = 'C:\srv\caddy\caddy.exe',
    [string]$HostCaddyfile = 'C:\srv\caddy\Caddyfile'
)
$ErrorActionPreference = 'Stop'
if (-not $PublicIp -or $PublicIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw 'PublicIp is required (parameter or $env:PUBLIC_IP).' }
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$hostName = "erp.$PublicIp.sslip.io"
$flag = 'C:\srv\portfolio\caddy\erp.public-enabled'
$siteFile = 'C:\srv\portfolio\caddy\erp.caddy'
$ctl = Join-Path $repo 'scripts\maintenance\erp-ctl.ps1'
$logDir = 'C:\srv\portfolio\erp\evidence\activation'; New-Item -ItemType Directory -Force $logDir | Out-Null

function Invoke-Caddy([string[]]$arguments) {
    $ErrorActionPreference = 'Continue'
    $out = & $CaddyExe @arguments 2>&1 | ForEach-Object { "$_" }
    $out | Where-Object { $_ -match 'Valid configuration|"level":"(warn|error)"' } | Out-Host
    return $LASTEXITCODE
}
function Invoke-Frappe([string]$name, [string[]]$a) {
    & $ctl frappe -LogFile (Join-Path $logDir "$name.log") -- @a
    if ($LASTEXITCODE -ne 0) { throw "$name failed (see $logDir\$name.log)" }
}
function Reload-Caddy {
    if ((Invoke-Caddy @('validate', '--config', $HostCaddyfile, '--adapter', 'caddyfile')) -ne 0) { throw 'caddy validate failed' }
    if ((Invoke-Caddy @('reload', '--config', $HostCaddyfile, '--adapter', 'caddyfile')) -ne 0) { throw 'caddy reload failed (running config unchanged)' }
}
function Disable-Public([string]$why) {
    Write-Warning "rolling back: $why"
    Remove-Item $siteFile, $flag -ErrorAction SilentlyContinue
    try { Reload-Caddy } catch { Write-Warning "caddy: $_" }
    try { Invoke-Frappe 'rollback-visitor-off' @('set-config', 'portfolio_visitor_enabled', '0', '--parse') } catch { Write-Warning "$_" }
    try { Invoke-Frappe 'rollback-host-name' @('set-config', 'host_name', 'http://127.0.0.1:8850') } catch { Write-Warning "$_" }
    try { & (Join-Path $PSScriptRoot 'deploy-portal.ps1') -PublicIp $PublicIp } catch { Write-Warning "portal refresh failed: $_" }
    Write-Host 'ERPNext is private (loopback only) again.'
}

if ($Rollback) { Disable-Public 'requested'; return }
if (-not $OwnerApproved) { throw 'Refusing: public ERPNext access needs explicit owner approval (-OwnerApproved, decision ERP-PUBLIC).' }

# ---- 1. preflight (no changes)
Write-Host '== preflight'
$down = @(Get-Service 'portfolio-erp-*' | Where-Object Status -ne 'Running')
if ($down -or @(Get-Service 'portfolio-erp-*').Count -lt 9) { throw "ERP services not all running: $($down.Name -join ', ')" }
if ((& curl.exe -s -o NUL -w '%{http_code}' 'http://127.0.0.1:8850/api/method/portfolio_sim.health.status') -ne '200') { throw 'ERP health is not 200' }
$open = @(Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -in 8850, 8851, 8852, 3408, 13102, 11102 -and $_.LocalAddress -ne '127.0.0.1' })
if ($open) { throw "ERP port listening outside loopback: $($open.LocalPort -join ', ')" }
if (-not (Test-Path 'C:\srv\portfolio\erp\runtime\bench\sites\assets\.installed-from')) { throw 'verified assets are not installed' }
Invoke-Frappe 'preflight-integrity' @('portfolio-sim', 'integrity')
Invoke-Frappe 'preflight-replay' @('portfolio-sim', 'replay-check')
$bk = Get-ScheduledTask -TaskName 'Portfolio - ERP nightly backup' -ErrorAction SilentlyContinue | Get-ScheduledTaskInfo
if (-not $bk -or $bk.LastTaskResult -ne 0) { throw 'nightly ERP backup task missing or last result not 0' }
Write-Host '  services, health, loopback, assets, integrity, replay, backup task: OK'

# ---- 2. visitor + production settings
Write-Host '== visitor and authentication settings'
Invoke-Frappe 'visitor-setup' @('portfolio-sim', 'visitor-setup')
Invoke-Frappe 'public-settings' @('portfolio-sim', 'public-settings')

# ---- 3. backup
Write-Host '== backup'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\maintenance\backup-erp.ps1') -VerifyRestore
if ($LASTEXITCODE -ne 0) { throw 'backup failed; nothing published' }

# ---- 4. publish
Write-Host '== publish'
try {
    Invoke-Frappe 'host-name' @('set-config', 'host_name', "https://$hostName")
    Invoke-Frappe 'visitor-on' @('set-config', 'portfolio_visitor_enabled', '1', '--parse')
    Set-Content -Path $flag -Value "approved $(Get-Date -Format o)" -Encoding ascii
    $tmpl = Get-Content (Join-Path $repo 'infrastructure\proxy\sites-inactive\erp-public.caddy.disabled') -Raw -Encoding UTF8
    [IO.File]::WriteAllText($siteFile, ($tmpl -replace '__PUBLIC_IP__', $PublicIp), (New-Object Text.UTF8Encoding $false))
    Reload-Caddy
} catch { Disable-Public "publish failed: $_"; throw }

# ---- 5. public checks
Write-Host '== public checks'
try {
    $ok = $false
    for ($i = 0; $i -lt 30 -and -not $ok; $i++) {   # the first request may wait for the certificate
        try { $r = Invoke-WebRequest -UseBasicParsing "https://$hostName/login" -TimeoutSec 60; $ok = $r.StatusCode -eq 200 } catch { Start-Sleep -Seconds 5 }
    }
    if (-not $ok) { throw 'login page not reachable over HTTPS' }
    if (-not $r.Headers['Strict-Transport-Security']) { throw 'HSTS header missing' }
    if ($r.Headers['Server']) { throw 'Server header exposed' }
    $internal = & curl.exe -s -o NUL -w '%{http_code}' "https://$hostName/api/method/portfolio_sim.health.status"
    if ($internal -ne '404') { throw "internal health endpoint public (HTTP $internal)" }
    $enter = & curl.exe -s -o NUL -D - "https://$hostName/api/method/portfolio_sim.visitor.enter"
    if (-not ($enter -match '^HTTP/\S+ 30[23]' -and ($enter -match '(?i)^location: /desk') -and ($enter -match '(?i)set-cookie: sid=[^;]+;.*secure'))) { throw 'visitor entry: expected redirect to /desk with a Secure session cookie' }
    Write-Host '  HTTPS, HSTS, no Server header, internal endpoints closed, visitor entry with Secure cookie: OK'
    if (-not $SkipBrowserTests) {
        $env:ERP_E2E_BASE_URL = "https://$hostName"; $env:ERP_E2E_VISITOR = '1'
        Push-Location (Join-Path $repo 'apps\erp\e2e')
        try { & npx.cmd playwright test erp-visitor.spec.ts erp-permissions.spec.ts -g 'visitor|guest' 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
        finally { Pop-Location; Remove-Item Env:ERP_E2E_VISITOR, Env:ERP_E2E_BASE_URL -ErrorAction SilentlyContinue }
        if ($code -ne 0) { throw 'public browser suite failed' }
    }
} catch { Disable-Public "$_"; throw }

# ---- 6. portal
try { & (Join-Path $PSScriptRoot 'deploy-portal.ps1') -PublicIp $PublicIp } catch { Write-Warning "portal refresh failed (ERP stays public): $_" }
Write-Host "ERPNext is public at https://$hostName (visitor entry: /api/method/portfolio_sim.visitor.enter)."
