<#
.SYNOPSIS
  Native Windows runtime for the portfolio POS (NexoPOS): PHP 8.3 NTS + isolated MariaDB 11.8. Idempotent.

.DESCRIPTION
  Expects the verified downloads in C:\srv\portfolio\pos\_downloads (see docs/DEPLOYMENT.md for URLs + SHA-256):
    php-8.3.36-1-nts-Win32-vs16-x64.zip, mariadb-11.8.10-winx64.zip, composer.phar
  1. Extracts PHP to C:\srv\portfolio\pos\php and writes php.ini (production base + NexoPOS extensions).
  2. Extracts MariaDB to C:\srv\portfolio\pos\mariadb, initialises a dedicated data directory, binds it to
     127.0.0.1:3307 only, and registers the Windows service `portfolio-pos-mariadb` (NETWORK SERVICE).
  3. Creates the `nexopos` database and a least-privilege `nexopos_app` account (localhost only).
  Credentials are generated here and stored only in C:\srv\portfolio\secrets\pos-mariadb.json
  (Administrators/SYSTEM). Nothing listens on a public interface.
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\srv\portfolio\pos',
    [int]$Port = 3307,
    [string]$Service = 'portfolio-pos-mariadb'
)
$ErrorActionPreference = 'Stop'
$dl = Join-Path $Root '_downloads'
$php = Join-Path $Root 'php'
$maria = Join-Path $Root 'mariadb'
$data = Join-Path $Root 'mariadb-data'
$secretFile = 'C:\srv\portfolio\secrets\pos-mariadb.json'

function Invoke-Native([string]$what, [scriptblock]$cmd) {
    $ErrorActionPreference = 'Continue'
    & $cmd 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}
function New-Secret([int]$len = 32) {
    $bytes = New-Object byte[] $len
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ([Convert]::ToBase64String($bytes) -replace '[+/=]', '').Substring(0, $len)
}

# --- 1. PHP --------------------------------------------------------------------------------------
if (-not (Test-Path "$php\php.exe")) { Expand-Archive "$dl\php-8.3.36-1-nts-Win32-vs16-x64.zip" $php -Force }
$ini = Get-Content "$php\php.ini-production" -Raw
$extensions = 'bcmath', 'curl', 'exif', 'fileinfo', 'gd', 'intl', 'mbstring', 'mysqli', 'openssl', 'pdo_mysql', 'sodium', 'zip'
foreach ($e in $extensions) { $ini = $ini -replace "(?m)^;extension=$e\s*$", "extension=$e" }
$ini = $ini -replace '(?m)^;\s*extension_dir = "ext"', 'extension_dir = "ext"'
$ini += @"

; ---- portfolio POS overrides ----
memory_limit = 256M
upload_max_filesize = 8M
post_max_size = 10M
max_execution_time = 60
date.timezone = UTC
expose_php = Off
display_errors = Off
log_errors = On
error_log = "$Root\logs\php-errors.log"
realpath_cache_size = 4096K
realpath_cache_ttl = 600
zend_extension = opcache
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 96
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 60
"@
Set-Content "$php\php.ini" $ini -Encoding ascii
New-Item -ItemType Directory -Force (Join-Path $Root 'logs') | Out-Null
Invoke-Native 'php modules' { & "$php\php.exe" -m }

# --- 2. MariaDB ----------------------------------------------------------------------------------
if (-not (Test-Path "$maria\bin\mariadbd.exe")) {
    Expand-Archive "$dl\mariadb-11.8.10-winx64.zip" "$Root\_mx" -Force
    Move-Item "$Root\_mx\mariadb-11.8.10-winx64" $maria
    Remove-Item "$Root\_mx"
}
if (Test-Path $secretFile) { $secret = Get-Content $secretFile -Raw | ConvertFrom-Json }
else {
    $secret = [pscustomobject]@{ root_password = New-Secret; app_user = 'nexopos_app'; app_password = New-Secret; database = 'nexopos'; host = '127.0.0.1'; port = $Port }
    $secret | ConvertTo-Json | Set-Content $secretFile -Encoding ascii
}

if (-not (Test-Path "$data\mysql")) {
    # The installer needs a password on the command line; it runs locally and is not logged.
    Invoke-Native 'mariadb-install-db' { & "$maria\bin\mariadb-install-db.exe" "--datadir=$data" "--port=$Port" "--password=$($secret.root_password)" '--default-user' }
}
$myIni = @"
[mysqld]
datadir=$($data.Replace('\','/'))
port=$Port
bind-address=127.0.0.1
skip-name-resolve
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
innodb_buffer_pool_size=128M
innodb_log_file_size=48M
performance_schema=OFF
max_connections=40
table_open_cache=400
log_error=$($Root.Replace('\','/'))/logs/mariadb.err
[client]
port=$Port
plugin-dir=$($maria.Replace('\','/'))/lib/plugin
"@
Set-Content "$data\my.ini" $myIni -Encoding ascii

$acct = 'NT AUTHORITY\NETWORK SERVICE'
icacls C:\srv\portfolio /grant "${acct}:(RX)" | Out-Null
icacls $Root /grant "${acct}:(RX)" | Out-Null
icacls $maria /grant "${acct}:(OI)(CI)(RX)" | Out-Null
icacls $data /grant "${acct}:(OI)(CI)(M)" | Out-Null
icacls (Join-Path $Root 'logs') /grant "${acct}:(OI)(CI)(M)" | Out-Null

if (-not (Get-Service $Service -ErrorAction SilentlyContinue)) {
    Invoke-Native 'service install' { & "$maria\bin\mariadbd.exe" --install $Service "--defaults-file=$data\my.ini" }
    Invoke-Native 'service account' { sc.exe config $Service obj= "NT AUTHORITY\NetworkService" start= auto }
}
if ((Get-Service $Service).Status -ne 'Running') { Start-Service $Service }

# --- 3. Database + least-privilege account -------------------------------------------------------
$sql = @"
CREATE DATABASE IF NOT EXISTS ``$($secret.database)`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$($secret.app_user)'@'127.0.0.1' IDENTIFIED BY '$($secret.app_password)';
CREATE USER IF NOT EXISTS '$($secret.app_user)'@'localhost' IDENTIFIED BY '$($secret.app_password)';
GRANT ALL PRIVILEGES ON ``$($secret.database)``.* TO '$($secret.app_user)'@'127.0.0.1';
GRANT ALL PRIVILEGES ON ``$($secret.database)``.* TO '$($secret.app_user)'@'localhost';
DELETE FROM mysql.global_priv WHERE User = '';
FLUSH PRIVILEGES;
"@
$env:MYSQL_PWD = $secret.root_password
try { Invoke-Native 'database setup' { $sql | & "$maria\bin\mariadb.exe" -u root -h 127.0.0.1 -P $Port --protocol=TCP } }
finally { Remove-Item Env:MYSQL_PWD }
Write-Host "POS runtime ready: PHP $(& "$php\php.exe" -r 'echo PHP_VERSION;'), MariaDB on 127.0.0.1:$Port ($Service)"
