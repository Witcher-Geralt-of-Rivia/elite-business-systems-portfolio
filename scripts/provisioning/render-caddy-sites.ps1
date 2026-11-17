<#
.SYNOPSIS
  Render portfolio Caddy site templates and hot-reload the host Caddy.

.DESCRIPTION
  - Substitutes __PUBLIC_IP__ in infrastructure/proxy/sites/*.caddy.tmpl
  - Writes results to C:\srv\portfolio\caddy\*.caddy
  - Validates the host Caddyfile, then runs `caddy reload` (graceful; never restarts the service)
  - On validation failure, restores the previously rendered files and aborts.

.PARAMETER PublicIp
  Public IPv4 of the VPS. Defaults to $env:PUBLIC_IP.
#>
[CmdletBinding()]
param(
    [string]$PublicIp = $env:PUBLIC_IP,
    [string]$CaddyExe = 'C:\srv\caddy\caddy.exe',
    [string]$HostCaddyfile = 'C:\srv\caddy\Caddyfile',
    [string]$OutDir = 'C:\srv\portfolio\caddy',
    [switch]$NoReload
)
$ErrorActionPreference = 'Stop'

if (-not $PublicIp -or $PublicIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    throw 'PublicIp is required (parameter or $env:PUBLIC_IP), e.g. 203.0.113.10'
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$templates = Get-ChildItem (Join-Path $repoRoot 'infrastructure\proxy\sites') -Filter '*.caddy.tmpl'
if (-not $templates) { throw 'No templates found.' }

New-Item -ItemType Directory -Force -Path $OutDir, 'C:\srv\portfolio\logs' | Out-Null

# Snapshot current rendered files for rollback.
$snapshot = Join-Path $env:TEMP ("portfolio-caddy-" + (Get-Date -Format 'yyyyMMddHHmmss'))
New-Item -ItemType Directory -Path $snapshot | Out-Null
Get-ChildItem $OutDir -Filter '*.caddy' -ErrorAction SilentlyContinue | Copy-Item -Destination $snapshot

foreach ($t in $templates) {
    $name = $t.Name -replace '\.tmpl$', ''
    $content = (Get-Content $t.FullName -Raw) -replace '__PUBLIC_IP__', $PublicIp
    [IO.File]::WriteAllText((Join-Path $OutDir $name), $content, (New-Object Text.UTF8Encoding $false))
    Write-Host "rendered $name"
}

& $CaddyExe validate --config $HostCaddyfile --adapter caddyfile 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'Validation failed - restoring previous rendered files.'
    Get-ChildItem $OutDir -Filter '*.caddy' | Remove-Item
    Get-ChildItem $snapshot | Copy-Item -Destination $OutDir
    throw 'caddy validate failed; nothing reloaded.'
}

if (-not $NoReload) {
    & $CaddyExe reload --config $HostCaddyfile --adapter caddyfile 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'caddy reload failed (running config unchanged).' }
    Write-Host 'caddy reloaded'
}
