<#
.SYNOPSIS
  Runs the POS browser tests against a dedicated local test instance of NexoPOS.

.DESCRIPTION
  -Mode isolated : clones the POS database into `nexopos_e2e` and runs the destructive specs (checkout,
                   refund, registers, product changes) against the clone; the clone is dropped afterwards.
                   The shared database is never written.
  -Mode visitor  : runs the read-only visitor specs against the real database (visitor writes are refused
                   by ShowcaseGuard; sessions use the cookie driver, so nothing is stored).
  The instance is PHP's built-in server on loopback with environment overrides (no config cache, loopback
  cookies, array cache, cookie sessions), so it never touches the production config, file cache or sessions.
  Credentials are read from C:\srv\portfolio\secrets (Administrators only) and passed via environment only.
#>
[CmdletBinding()]
param(
    [ValidateSet('isolated', 'visitor')] [string]$Mode = 'isolated',
    [string[]]$Spec,
    [switch]$KeepDatabase,
    # Application tree to serve (e.g. a staging copy with an undeployed module build).
    [string]$AppRoot = 'C:\srv\portfolio\pos\app'
)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$app = $AppRoot
$php = 'C:\srv\portfolio\pos\php\php.exe'
$bin = 'C:\srv\portfolio\pos\mariadb\bin'
$secret = Get-Content 'C:\srv\portfolio\secrets\pos-mariadb.json' -Raw | ConvertFrom-Json
$admin = Get-Content 'C:\srv\portfolio\secrets\pos-admin-account.json' -Raw | ConvertFrom-Json
$port = if ($Mode -eq 'isolated') { 8830 } else { 8831 }
$db = if ($Mode -eq 'isolated') { 'nexopos_e2e' } else { $secret.database }
$conn = @('-u', 'root', '-h', '127.0.0.1', '-P', "$($secret.port)", '--protocol=TCP')
$work = Join-Path $env:TEMP "pos-e2e-$Mode"
New-Item -ItemType Directory -Force $work | Out-Null

function Invoke-Maria([string[]]$a, [string]$stdin) {
    $ErrorActionPreference = 'Continue'
    if ($stdin) { $out = Get-Content $stdin -Raw | & (Join-Path $bin 'mariadb.exe') @a 2>&1 } else { $out = & (Join-Path $bin 'mariadb.exe') @a 2>&1 }
    $out | Where-Object { "$_" -notmatch 'ssl-verify-server-cert' } | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "mariadb failed ($LASTEXITCODE)" }
}

$env:MYSQL_PWD = $secret.root_password
try {
    if ($Mode -eq 'isolated') {
        Write-Host "cloning $($secret.database) -> $db"
        $dump = Join-Path $work 'clone.sql'
        $ErrorActionPreference = 'Continue'
        & (Join-Path $bin 'mariadb-dump.exe') @conn --single-transaction --default-character-set=utf8mb4 --result-file=$dump $secret.database 2>&1 | Where-Object { "$_" -notmatch 'ssl-verify' }
        if ($LASTEXITCODE -ne 0) { throw 'dump failed' }
        $ErrorActionPreference = 'Stop'
        Invoke-Maria ($conn + @('-e', "DROP DATABASE IF EXISTS $db; CREATE DATABASE $db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON $db.* TO '$($secret.app_user)'@'127.0.0.1'; GRANT ALL PRIVILEGES ON $db.* TO '$($secret.app_user)'@'localhost';"))
        Invoke-Maria ($conn + @($db)) $dump
        Remove-Item $dump
    }

    # Test instance environment (inherited by the child process only).
    $env:APP_CONFIG_CACHE = Join-Path $work 'no-config-cache.php'   # does not exist: config is read from env/.env
    $env:APP_URL = "http://127.0.0.1:$port"
    $env:APP_DEBUG = 'false'
    $env:DB_DATABASE = $db
    $env:SESSION_DRIVER = 'cookie'
    $env:SESSION_DOMAIN = 'null'   # '' would delete the variable (PowerShell) and fall back to the public domain in .env
    $env:SESSION_SECURE_COOKIE = 'false'
    $env:SANCTUM_STATEFUL_DOMAINS = "127.0.0.1:$port"
    $env:CACHE_DRIVER = 'array'
    $env:CACHE_STORE = 'array'
    $router = Join-Path $app 'vendor\laravel\framework\src\Illuminate\Foundation\resources\server.php'
    $server = Start-Process $php -ArgumentList '-d', 'opcache.enable_cli=1', '-d', 'memory_limit=512M', '-S', "127.0.0.1:$port", '-t', '.', $router `
        -WorkingDirectory (Join-Path $app 'public') -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work 'server.out') -RedirectStandardError (Join-Path $work 'server.err')
    try {
        $ready = $false
        for ($i = 0; $i -lt 90 -and -not $ready; $i++) {
            Start-Sleep -Seconds 2
            try { $ready = (Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$port/sign-in" -TimeoutSec 60).StatusCode -eq 200 } catch { }
        }
        if (-not $ready) { Get-Content (Join-Path $work 'server.err') -Tail 20; throw 'test instance did not start' }
        Write-Host "test instance ready on 127.0.0.1:$port ($db)"

        $env:POS_E2E_BASE_URL = "http://127.0.0.1:$port"
        $env:POS_E2E_ADMIN_USER = $admin.username
        $env:POS_E2E_ADMIN_PASSWORD = $admin.password
        $env:POS_E2E_MODE = $Mode
        $specs = @(if ($Spec) { $Spec } elseif ($Mode -eq 'isolated') { @('pos-admin.spec.ts') } else { @('pos-visitor.spec.ts') })
        Push-Location (Join-Path $repo 'apps\pos\e2e')
        $ErrorActionPreference = 'Continue'
        npx playwright test $specs 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^\s+at ' }
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Pop-Location
        Write-Host "playwright exit=$code"
        if ($Mode -eq 'visitor') {
            # Database-level proof that the visitor session persisted nothing.
            $sql = "SELECT (SELECT COUNT(*) FROM nexopos_orders WHERE author_id = u.id) + (SELECT COUNT(*) FROM nexopos_registers_history WHERE author_id = u.id) + (SELECT COUNT(*) FROM nexopos_products_histories WHERE author_id = u.id) + (SELECT COUNT(*) FROM nexopos_products WHERE author_id = u.id) FROM nexopos_users u WHERE u.email = 'visitor@showcase.harborandpine.example';"
            $ErrorActionPreference = 'Continue'
            $written = (& (Join-Path $bin 'mariadb.exe') @conn -N -B $db -e $sql 2>&1 | Where-Object { "$_" -notmatch 'ssl' } | Select-Object -First 1)
            $ErrorActionPreference = 'Stop'
            Write-Host "records authored by the visitor: $written"
            if ("$written".Trim() -ne '0') { $code = 1; Write-Host 'FAIL: the visitor persisted records' }
        }
        $global:LASTEXITCODE = $code
    } finally {
        taskkill /T /F /PID $server.Id 2>&1 | Out-Null
        Remove-Item Env:POS_E2E_ADMIN_PASSWORD -ErrorAction SilentlyContinue
    }
} finally {
    if ($Mode -eq 'isolated' -and -not $KeepDatabase) {
        try { Invoke-Maria ($conn + @('-e', "DROP DATABASE IF EXISTS $db;")) } catch { Write-Host "could not drop ${db}: $_" }
    }
    Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
}
