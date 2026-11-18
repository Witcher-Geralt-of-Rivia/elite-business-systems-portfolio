<#
.SYNOPSIS
  Installs/refreshes the two php-cgi FastCGI worker services for the portfolio POS (127.0.0.1:9071-9072). Idempotent.
#>
[CmdletBinding()]
param([string]$WinSW = 'C:\srv\caddy\caddy-service.exe')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$svcDir = 'C:\srv\portfolio\pos\services'
$logDir = 'C:\srv\portfolio\logs\pos-php'
New-Item -ItemType Directory -Force $svcDir, $logDir | Out-Null
$acct = 'NT AUTHORITY\LOCAL SERVICE'
icacls $svcDir /grant "${acct}:(OI)(CI)(RX)" | Out-Null   # the wrapper exe + xml live here
icacls C:\srv\portfolio\pos\php /grant "${acct}:(OI)(CI)(RX)" | Out-Null
icacls C:\srv\portfolio\logs /grant "${acct}:(RX)" | Out-Null
icacls $logDir /grant "${acct}:(OI)(CI)(M)" | Out-Null
icacls C:\srv\portfolio\pos\logs /grant "${acct}:(OI)(CI)(M)" | Out-Null

foreach ($n in 1, 2) {
    $id = "portfolio-pos-php-$n"
    $exe = Join-Path $svcDir "$id.exe"
    $installed = [bool](Get-Service $id -ErrorAction SilentlyContinue)
    if ($installed) { Stop-Service $id -ErrorAction SilentlyContinue; (Get-Service $id).WaitForStatus('Stopped', '00:00:20') }
    Copy-Item $WinSW $exe -Force
    Copy-Item (Join-Path $repo "infrastructure\windows\services\$id.xml") (Join-Path $svcDir "$id.xml") -Force
    if (-not $installed) {
        $ErrorActionPreference = 'Continue'; & $exe install 2>&1 | Out-Host; $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -ne 0) { throw "install $id failed" }
    }
    Start-Service $id
}
Get-Service portfolio-pos-php-* | Format-Table Name, Status, StartType
