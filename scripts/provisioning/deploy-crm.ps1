<#
.SYNOPSIS
  Build and deploy the portfolio CRM (API service + static UI) on the Windows host. Idempotent.

.DESCRIPTION
  1. Copies apps/crm/backend (no tests) to C:\srv\portfolio\crm\api and installs production deps.
  2. Applies database migrations (needs CRM_MIGRATION_DATABASE_URL in the env file).
  3. Builds apps/crm/frontend and publishes dist\ to C:\srv\portfolio\crm\www (with an empty runtime config.js).
  4. Installs/updates the WinSW service `portfolio-crm-api` and restarts it; waits for /api/health.
  5. Renders Caddy sites and hot-reloads Caddy.

  Secrets stay in C:\srv\portfolio\secrets (Administrators/SYSTEM; the service account gets read on its env file only).
#>
[CmdletBinding()]
param(
    [string]$PublicIp = $env:PUBLIC_IP,
    [string]$EnvFile = 'C:\srv\portfolio\secrets\crm-api.env',            # crm_app only; readable by the service
    [string]$MigrateEnvFile = 'C:\srv\portfolio\secrets\crm-migrate.env', # superuser URL; Administrators only
    [string]$WinSW = 'C:\srv\caddy\caddy-service.exe',
    [switch]$SkipFrontend
)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$apiDir = 'C:\srv\portfolio\crm\api'
$wwwDir = 'C:\srv\portfolio\crm\www'
$filesDir = 'C:\srv\portfolio\crm\files'
$logDir = 'C:\srv\portfolio\logs\crm-api'
$svc = 'portfolio-crm-api'

# Windows PowerShell 5.1 turns native stderr lines (warnings, notices) into error records, which
# 'Stop' makes fatal. Judge native tools by exit code only, and still show their output.
function Invoke-Native([string]$what, [scriptblock]$cmd) {
    $ErrorActionPreference = 'Continue'
    & $cmd 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}

New-Item -ItemType Directory -Force -Path $apiDir, $wwwDir, $filesDir, $logDir | Out-Null

# --- 1. API code -------------------------------------------------------------------------------
$backend = Join-Path $repo 'apps\crm\backend'
# The service wrapper (exe/xml/logs) lives in the same folder and is managed in step 4: keep it out of the mirror.
robocopy $backend $apiDir /MIR /XD node_modules test .git /XF .env .env.* "$svc.exe" "$svc.xml" "$svc.*.log" /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
Push-Location $apiDir
try { Invoke-Native 'npm ci (api)' { npm ci --omit=dev --no-audit --no-fund --loglevel=error } } finally { Pop-Location }

# --- 2. Migrations ------------------------------------------------------------------------------
Push-Location $apiDir
try { Invoke-Native 'migrate' { node "--env-file=$MigrateEnvFile" scripts/migrate.ts } } finally { Pop-Location }

# --- 3. Frontend --------------------------------------------------------------------------------
if (-not $SkipFrontend) {
    $frontend = Join-Path $repo 'apps\crm\frontend'
    Push-Location $frontend
    try { Invoke-Native 'vite build' { npx vite build --logLevel warn } } finally { Pop-Location }
    robocopy (Join-Path $frontend 'dist') $wwwDir /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy (www) failed ($LASTEXITCODE)" }
    # Runtime config: the portfolio providers need no Supabase settings.
    Set-Content (Join-Path $wwwDir 'config.js') 'window._atomicCrmConfig = {};' -Encoding ascii
}

# --- 4. Service ---------------------------------------------------------------------------------
$acct = 'NT AUTHORITY\LOCAL SERVICE'
icacls C:\srv\portfolio /grant "${acct}:(RX)" | Out-Null
icacls C:\srv\portfolio\crm /grant "${acct}:(RX)" | Out-Null
icacls $apiDir /grant "${acct}:(OI)(CI)(RX)" | Out-Null
icacls $filesDir /grant "${acct}:(OI)(CI)(M)" | Out-Null
icacls $logDir /grant "${acct}:(OI)(CI)(M)" | Out-Null
icacls C:\srv\portfolio\logs /grant "${acct}:(RX)" | Out-Null
icacls C:\srv\portfolio\secrets /grant "${acct}:(RX)" | Out-Null          # traverse/list only (no inheritance)
icacls $EnvFile /grant "${acct}:(R)" | Out-Null                             # its own env file only
icacls C:\srv\portfolio\crm\www /grant "NT SERVICE\caddy:(OI)(CI)(RX)" | Out-Null

$exe = Join-Path $apiDir "$svc.exe"
$installed = [bool](Get-Service $svc -ErrorAction SilentlyContinue)
# The wrapper exe is locked while the service runs: stop first, then replace exe + xml.
if ($installed) { Stop-Service $svc -ErrorAction SilentlyContinue; (Get-Service $svc).WaitForStatus('Stopped', '00:00:30') }
Copy-Item $WinSW $exe -Force
Copy-Item (Join-Path $repo 'infrastructure\windows\services\portfolio-crm-api.xml') (Join-Path $apiDir "$svc.xml") -Force
# WinSW 2.x reads the XML at every start, so an installed service needs no refresh command.
if (-not $installed) { Invoke-Native 'service install' { & $exe install } }
Start-Service $svc

$deadline = (Get-Date).AddSeconds(30)
do {
    Start-Sleep -Milliseconds 700
    try { $health = Invoke-RestMethod http://127.0.0.1:8810/api/health -TimeoutSec 3 } catch { $health = $null }
} until ($health.status -eq 'ok' -or (Get-Date) -gt $deadline)
if ($health.status -ne 'ok') { throw "API did not become healthy; see $logDir" }
Write-Host 'api healthy'

# --- 5. Proxy -----------------------------------------------------------------------------------
& (Join-Path $PSScriptRoot 'render-caddy-sites.ps1') -PublicIp $PublicIp
