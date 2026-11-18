<#
.SYNOPSIS
  Backup of the POS (NexoPOS) MariaDB database with retention and an optional restore check.

.DESCRIPTION
  Writes C:\srv\portfolio\backups\pos\pos-<yyyyMMdd-HHmmss>.sql (mariadb-dump --single-transaction,
  consistent without locking the live store) plus a .sha256 file, deletes dumps older than -RetentionDays,
  and with -VerifyRestore restores the dump into a scratch database (the mariadb client reads the file
  itself: piping it through PowerShell 5.1 would re-encode non-ASCII text), compares row counts of the
  business tables and a checksum of text columns (names, SKUs, e-mails), then drops the scratch database.
  Root credentials come from
  C:\srv\portfolio\secrets\pos-mariadb.json (Administrators/SYSTEM only) via MYSQL_PWD, never argv.
  Intended to run as SYSTEM from Task Scheduler; exits non-zero on any failure.
#>
[CmdletBinding()]
param(
    [string]$OutDir = 'C:\srv\portfolio\backups\pos',
    [int]$RetentionDays = 14,
    [switch]$VerifyRestore
)
$ErrorActionPreference = 'Stop'
$logDir = 'C:\srv\portfolio\logs\maintenance'
New-Item -ItemType Directory -Force $logDir, $OutDir | Out-Null
Start-Transcript -Path (Join-Path $logDir "backup-pos-$(Get-Date -Format yyyyMMdd).log") -Append | Out-Null
trap { Write-Host "FAILED: $_"; Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue; Stop-Transcript | Out-Null; exit 1 }

$bin = 'C:\srv\portfolio\pos\mariadb\bin'
$secret = Get-Content 'C:\srv\portfolio\secrets\pos-mariadb.json' -Raw | ConvertFrom-Json
$env:MYSQL_PWD = $secret.root_password
$conn = @('-u', 'root', '-h', '127.0.0.1', '-P', "$($secret.port)", '--protocol=TCP')
$stamp = Get-Date -Format yyyyMMdd-HHmmss
$sql = Join-Path $OutDir "pos-$stamp.sql"

function Invoke-Maria([string]$exe, [string[]]$a) {
    $ErrorActionPreference = 'Continue'
    & (Join-Path $bin $exe) @a 2>&1 | Where-Object { $_ -notmatch 'ssl-verify-server-cert' } | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "$exe failed ($LASTEXITCODE)" }
}

# 1. Consistent dump of the live database (InnoDB snapshot, no global lock).
$ErrorActionPreference = 'Continue'
& (Join-Path $bin 'mariadb-dump.exe') @conn --single-transaction --routines --triggers --default-character-set=utf8mb4 --result-file=$sql $secret.database 2>&1 |
    Where-Object { $_ -notmatch 'ssl-verify-server-cert' } | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { throw "mariadb-dump failed ($LASTEXITCODE)" }
$ErrorActionPreference = 'Stop'
$hash = (Get-FileHash $sql -Algorithm SHA256).Hash.ToLower()
"$hash  $(Split-Path $sql -Leaf)" | Set-Content "$sql.sha256" -Encoding ascii
Write-Host ("backup {0} ({1:N1} MB) sha256={2}" -f (Split-Path $sql -Leaf), ((Get-Item $sql).Length / 1MB), $hash.Substring(0, 16))

# 2. Optional restore check into a scratch database.
if ($VerifyRestore) {
    $scratch = 'pos_restore_check'
    $tables = 'nexopos_orders', 'nexopos_orders_products', 'nexopos_orders_payments', 'nexopos_products', 'nexopos_procurements', 'nexopos_registers_history', 'nexopos_products_histories'
    Invoke-Maria 'mariadb.exe' ($conn + @('-e', "DROP DATABASE IF EXISTS $scratch; CREATE DATABASE $scratch CHARACTER SET utf8mb4;"))
    $ErrorActionPreference = 'Continue'
    & (Join-Path $bin 'mariadb.exe') @conn --default-character-set=utf8mb4 $scratch -e "source $($sql -replace '\\', '/')" 2>&1 | Where-Object { $_ -notmatch 'ssl-verify' } | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "restore failed ($LASTEXITCODE)" }
    $ErrorActionPreference = 'Stop'
    $diff = @()
    foreach ($t in $tables) {
        $live = (& (Join-Path $bin 'mariadb.exe') @conn -N -e "select count(*) from $($secret.database).$t" 2>$null)
        $restored = (& (Join-Path $bin 'mariadb.exe') @conn -N -e "select count(*) from $scratch.$t" 2>$null)
        # The live store may have sold something since the dump: the restore must not have MORE rows.
        if ([int]$restored -gt [int]$live -or [int]$restored -eq 0 -and [int]$live -gt 0) { $diff += "$t live=$live restored=$restored" }
        Write-Host "  $t live=$live restored=$restored"
    }
    # Content fidelity: checksum of text columns over the rows present in the restore (ids <= restored max).
    $content = [ordered]@{ nexopos_products = 'name, sku, barcode'; nexopos_products_categories = 'name'; nexopos_registers = 'name'
        nexopos_users = 'username, email, first_name, last_name'; nexopos_orders = 'code' }
    foreach ($t in $content.Keys) {
        $max = (& (Join-Path $bin 'mariadb.exe') @conn -N -e "select coalesce(max(id),0) from $scratch.$t" 2>$null)
        $q = { param($db) "select concat(count(*), ':', coalesce(sum(crc32(concat_ws('|', $($content[$t])))),0)) from $db.$t where id <= $max" }
        $a = (& (Join-Path $bin 'mariadb.exe') @conn --default-character-set=utf8mb4 -N -e (& $q $secret.database) 2>$null)
        $b = (& (Join-Path $bin 'mariadb.exe') @conn --default-character-set=utf8mb4 -N -e (& $q $scratch) 2>$null)
        if (-not $b -or $a -ne $b) { $diff += "$t content live=$a restored=$b" }
        Write-Host "  $t content live=$a restored=$b"
    }
    Invoke-Maria 'mariadb.exe' ($conn + @('-e', "DROP DATABASE $scratch;"))
    if ($diff) { throw "restore check mismatch: $($diff -join '; ')" }
    Write-Host 'restore check OK'
}

# 3. Retention.
Get-ChildItem $OutDir -Filter 'pos-*.sql*' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } | Remove-Item
Remove-Item Env:MYSQL_PWD
Stop-Transcript | Out-Null
exit 0
