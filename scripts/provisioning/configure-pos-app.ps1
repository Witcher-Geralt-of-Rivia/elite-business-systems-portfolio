<#
.SYNOPSIS
  Configures the NexoPOS application in C:\srv\portfolio\pos\app for production behind Caddy. Idempotent.

.DESCRIPTION
  - Writes .env (keeps the existing APP_KEY) with the MariaDB credentials from
    C:\srv\portfolio\secrets\pos-mariadb.json, HTTPS URL, secure cookies, no debug, no broadcasting/mail.
  - Restricts .env to Administrators/SYSTEM + the PHP service account (read).
  - Grants the PHP service account write access to storage\ and bootstrap\cache\ only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$PublicIp,
    [string]$App = 'C:\srv\portfolio\pos\app',
    [string]$ServiceAccount = 'NT AUTHORITY\LOCAL SERVICE'
)
$ErrorActionPreference = 'Stop'
$secret = Get-Content 'C:\srv\portfolio\secrets\pos-mariadb.json' -Raw | ConvertFrom-Json
$envFile = Join-Path $App '.env'
$host_ = "pos.$PublicIp.sslip.io"

$current = @{}
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) { if ($line -match '^([A-Z0-9_]+)=(.*)$') { $current[$Matches[1]] = $Matches[2] } }
}
$values = [ordered]@{
    APP_NAME              = '"Harbor & Pine Market"'
    APP_ENV               = 'production'
    APP_KEY               = $current['APP_KEY']
    APP_DEBUG             = 'false'
    APP_URL               = "https://$host_"
    LOG_CHANNEL           = 'daily'
    LOG_LEVEL             = 'warning'
    DB_CONNECTION         = 'mysql'
    DB_HOST               = $secret.host
    DB_PORT               = $secret.port
    DB_DATABASE           = $secret.database
    DB_USERNAME           = $secret.app_user
    DB_PASSWORD           = $secret.app_password
    BROADCAST_DRIVER      = 'log'
    CACHE_DRIVER          = 'file'
    QUEUE_CONNECTION      = 'sync'
    SESSION_DRIVER        = 'file'
    SESSION_LIFETIME      = '120'
    SESSION_DOMAIN        = $host_
    SESSION_SECURE_COOKIE = 'true'
    SESSION_COOKIE        = 'nexopos_session'
    MAIL_MAILER           = 'log'
    SANCTUM_STATEFUL_DOMAINS = $host_
    NS_ENV                = 'production'
    TELESCOPE_ENABLED     = 'false'
}
if (-not $values.APP_KEY) { throw 'APP_KEY missing: run `php artisan key:generate` once first' }
($values.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n" | Set-Content $envFile -Encoding ascii

icacls $envFile /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' "${ServiceAccount}:R" | Out-Null
icacls C:\srv\portfolio\pos /grant "${ServiceAccount}:(RX)" | Out-Null
icacls $App /grant "${ServiceAccount}:(OI)(CI)(RX)" | Out-Null
foreach ($w in 'storage', 'bootstrap\cache') { icacls (Join-Path $App $w) /grant "${ServiceAccount}:(OI)(CI)(M)" | Out-Null }
icacls (Join-Path $App 'public') /grant 'NT SERVICE\caddy:(OI)(CI)(RX)' | Out-Null
# public\lang is NexoPOS's junction to <app>\lang (translation JSON, public data); Caddy's file server
# follows it with the target's ACL, so without this grant /lang/<locale>.json falls through to Laravel (404).
icacls (Join-Path $App 'lang') /grant 'NT SERVICE\caddy:(OI)(CI)(RX)' | Out-Null
icacls C:\srv\portfolio\pos /grant 'NT SERVICE\caddy:(RX)' | Out-Null
icacls $App /grant 'NT SERVICE\caddy:(RX)' | Out-Null
Write-Host "configured $envFile for https://$host_"
