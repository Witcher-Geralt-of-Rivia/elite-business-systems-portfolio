<#
.SYNOPSIS
  Installs/refreshes the Harbor & Pine Market live simulation worker service (portfolio-pos-sim). Idempotent.
  Start it only after the history backfill has finished (the worker continues from the backfill watermark).
#>
[CmdletBinding()]
param([string]$WinSW = 'C:\srv\caddy\caddy-service.exe', [switch]$NoStart)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$svcDir = 'C:\srv\portfolio\pos\services'
$logDir = 'C:\srv\portfolio\logs\pos-sim'
$id = 'portfolio-pos-sim'
$acct = 'NT AUTHORITY\LOCAL SERVICE'
New-Item -ItemType Directory -Force $svcDir, $logDir | Out-Null
icacls $svcDir /grant "${acct}:(OI)(CI)(RX)" | Out-Null
icacls $logDir /grant "${acct}:(OI)(CI)(M)" | Out-Null

$exe = Join-Path $svcDir "$id.exe"
$installed = [bool](Get-Service $id -ErrorAction SilentlyContinue)
if ($installed) { Stop-Service $id -ErrorAction SilentlyContinue; (Get-Service $id).WaitForStatus('Stopped', '00:01:00') }
Copy-Item $WinSW $exe -Force
Copy-Item (Join-Path $repo "infrastructure\windows\services\$id.xml") (Join-Path $svcDir "$id.xml") -Force
if (-not $installed) {
    $ErrorActionPreference = 'Continue'; & $exe install 2>&1 | Out-Host; $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0) { throw "install $id failed" }
}
if (-not $NoStart) { Start-Service $id }
Get-Service $id | Format-Table Name, Status, StartType
