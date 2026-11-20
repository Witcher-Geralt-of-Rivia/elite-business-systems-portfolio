<#
.SYNOPSIS
  Backup of the native-Windows ERPNext site (database, files, site configuration) with retention and a restore check
  in a separate scratch environment. No Unix shell pipelines (Frappe's own `bench backup` uses them).

.DESCRIPTION
  Writes C:\srv\portfolio\backups\erp\erp-<yyyyMMdd-HHmmss>\:
    database.sql.gz      mariadb-dump --single-transaction (consistent InnoDB snapshot, no lock on the live site),
                         gzip-compressed in-process; restorable with Frappe's restore as well
    files.zip            sites\<site>\public\files and private\files
    site_config.json     database credentials and the site's encryption key (needed to read encrypted fields)
    manifest.json        SHA-256 of each file, app commits, row counts of key tables, simulation status
  Retention: -RetentionDays (default 14).

  -VerifyRestore restores the backup into a SEPARATE, temporary MariaDB instance (own data directory under
  C:\srv\portfolio\erp\scratch, own port, random credentials, below-normal priority), compares row counts and a
  text/amount checksum of key tables with the values recorded at dump time, re-hashes the extracted files, then
  shuts the scratch instance down and deletes it. -DeepVerify additionally points a throwaway Frappe site at the
  restored database and runs `portfolio-sim status` and `portfolio-sim integrity` (all checks must be 0) on it.
  The live ERP database is only read (dump + counts inside the same snapshot); CRM, POS and the co-hosted app are
  not touched. Intended to run as SYSTEM from Task Scheduler; exits non-zero on any failure.
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\srv\portfolio\erp\runtime',
    [string]$Site = 'erp.portfolio.local',
    [string]$OutDir = 'C:\srv\portfolio\backups\erp',
    [int]$RetentionDays = 14,
    [switch]$VerifyRestore,
    [switch]$DeepVerify,
    [int]$ScratchPort = 3409
)
$ErrorActionPreference = 'Stop'
if ($DeepVerify) { $VerifyRestore = $true }
$logDir = 'C:\srv\portfolio\logs\maintenance'
New-Item -ItemType Directory -Force $logDir, $OutDir | Out-Null
Start-Transcript -Path (Join-Path $logDir "backup-erp-$(Get-Date -Format yyyyMMdd).log") -Append | Out-Null
$scratchProc = $null; $scratchDir = $null; $scratchSite = $null
function Stop-Scratch {
    if ($script:scratchProc -and -not $script:scratchProc.HasExited) {
        $env:MYSQL_PWD = $script:scratchPw
        & (Join-Path $bin 'mariadb-admin.exe') -u root -h 127.0.0.1 -P $ScratchPort --protocol=TCP shutdown 2>$null | Out-Null
        if (-not $script:scratchProc.WaitForExit(60000)) { $script:scratchProc.Kill() }
    }
    if ($script:scratchSite -and (Test-Path $script:scratchSite)) { Remove-Item $script:scratchSite -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:scratchDir -and (Test-Path $script:scratchDir)) { Remove-Item $script:scratchDir -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
}
trap { Write-Host "FAILED: $_"; Stop-Scratch; Stop-Transcript | Out-Null; exit 1 }

$bin = Join-Path $Root 'mariadb\bin'
$sites = Join-Path $Root 'bench\sites'
$siteDir = Join-Path $sites $Site
$siteConfig = Get-Content (Join-Path $siteDir 'site_config.json') -Raw | ConvertFrom-Json
$common = Get-Content (Join-Path $sites 'common_site_config.json') -Raw | ConvertFrom-Json
$db = $siteConfig.db_name
$port = if ($siteConfig.db_port) { $siteConfig.db_port } else { $common.db_port }
$stamp = Get-Date -Format yyyyMMdd-HHmmss
$dest = Join-Path $OutDir "erp-$stamp"
New-Item -ItemType Directory -Force $dest | Out-Null

function Invoke-Exe([string]$exe, [string[]]$a, [string]$pw) {
    $env:MYSQL_PWD = $pw
    $ErrorActionPreference = 'Continue'
    $out = & $exe @a 2>&1 | Where-Object { "$_" -notmatch 'ssl-verify-server-cert' } | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw "$(Split-Path $exe -Leaf) failed ($code): $($out -join ' ')" }
    return $out
}
function Get-Rows([int]$p, [string]$pw, [string]$user, [string]$database, [string]$query) {
    Invoke-Exe (Join-Path $bin 'mariadb.exe') @('-u', $user, '-h', '127.0.0.1', '-P', "$p", '--protocol=TCP', '--default-character-set=utf8mb4', '-N', '-B', $database, '-e', $query) $pw
}
function Compress-Gzip([string]$src, [string]$dst) {
    $in = [IO.File]::OpenRead($src); $out = [IO.File]::Create($dst)
    try { $gz = [IO.Compression.GZipStream]::new($out, [IO.Compression.CompressionLevel]::Optimal); $in.CopyTo($gz); $gz.Dispose() } finally { $in.Dispose(); $out.Dispose() }
}
function Expand-Gzip([string]$src, [string]$dst) {
    $in = [IO.File]::OpenRead($src); $out = [IO.File]::Create($dst)
    try { $gz = [IO.Compression.GZipStream]::new($in, [IO.Compression.CompressionMode]::Decompress); $gz.CopyTo($out); $gz.Dispose() } finally { $in.Dispose(); $out.Dispose() }
}
function Get-Sha([string]$p) { (Get-FileHash $p -Algorithm SHA256).Hash.ToLower() }

# Checks recorded at dump time and compared after the restore. Counts of submitted documents and ledgers, plus a
# checksum over identifying text and amounts (exact string form of DECIMAL values).
$checks = [ordered]@{
    'sim_ledger' = 'select concat(count(*), '':'', coalesce(sum(crc32(concat_ws(''|'', name, kind, outcome, reference_name))),0)) from `tabDistribution Sim Event`'
    'gl' = 'select concat(count(*), '':'', coalesce(sum(crc32(concat_ws(''|'', voucher_no, account, debit, credit))),0)) from `tabGL Entry` where is_cancelled = 0'
    'sle' = 'select concat(count(*), '':'', coalesce(sum(crc32(concat_ws(''|'', voucher_no, item_code, warehouse, actual_qty, stock_value_difference))),0)) from `tabStock Ledger Entry` where is_cancelled = 0'
    'sales_invoice' = 'select concat(count(*), '':'', coalesce(sum(crc32(concat_ws(''|'', name, customer, grand_total, outstanding_amount))),0)) from `tabSales Invoice` where docstatus = 1'
    'purchase_invoice' = 'select concat(count(*), '':'', coalesce(sum(crc32(concat_ws(''|'', name, supplier, grand_total, outstanding_amount))),0)) from `tabPurchase Invoice` where docstatus = 1'
    'payment_entry' = 'select concat(count(*), '':'', coalesce(sum(crc32(concat_ws(''|'', name, party, paid_amount))),0)) from `tabPayment Entry` where docstatus = 1'
    'users' = 'select concat(count(*), '':'', coalesce(sum(crc32(concat_ws(''|'', name, enabled))),0)) from `tabUser`'
    'files' = 'select concat(count(*), '':'', coalesce(sum(crc32(concat_ws(''|'', name, file_url))),0)) from `tabFile`'
}

# --- 1. Consistent dump (--single-transaction: one InnoDB snapshot; the live site keeps running).
$sql = Join-Path $dest 'database.sql'
$conn = @('-u', $db, '-h', '127.0.0.1', '-P', "$port", '--protocol=TCP')
$t0 = Get-Date
Invoke-Exe (Join-Path $bin 'mariadb-dump.exe') ($conn + @('--single-transaction', '--quick', '--routines', '--triggers', '--hex-blob', '--default-character-set=utf8mb4', "--result-file=$sql", $db)) $siteConfig.db_password | Out-Null
$dumpSeconds = [int]((Get-Date) - $t0).TotalSeconds
Compress-Gzip $sql "$sql.gz"

# --- 2. Files and configuration
$filesZip = Join-Path $dest 'files.zip'
$stage = Join-Path $dest '_files'
New-Item -ItemType Directory -Force $stage | Out-Null
foreach ($part in 'public\files', 'private\files') {
    $src = Join-Path $siteDir $part
    if (Test-Path $src) { robocopy $src (Join-Path $stage $part) /E /NFL /NDL /NJH /NJS /NP | Out-Null; if ($LASTEXITCODE -ge 8) { throw "robocopy $part failed" } }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $filesZip, [IO.Compression.CompressionLevel]::Optimal, $false)
$fileHashes = [ordered]@{}
Get-ChildItem $stage -Recurse -File | Sort-Object FullName | ForEach-Object { $fileHashes[$_.FullName.Substring($stage.Length + 1).Replace('\', '/')] = Get-Sha $_.FullName }
Remove-Item $stage -Recurse -Force
Copy-Item (Join-Path $siteDir 'site_config.json') (Join-Path $dest 'site_config.json')

# --- 3. Manifest. The check values are taken from the live database right after the dump. The live site may have
#        moved on since the snapshot, so the restore check accepts a restored count that is lower than live, requires
#        identical content when the counts are equal, and requires the restored snapshot to be internally consistent
#        (ledger rows = executed events; -DeepVerify: the application's own integrity checks).
$commits = [ordered]@{}
# Read .git\HEAD directly: as SYSTEM, git refuses repositories owned by another account ("dubious ownership").
foreach ($app in 'frappe', 'erpnext') { $commits[$app] = (Get-Content (Join-Path $Root "bench\apps\$app\.git\HEAD") -Raw).Trim() }
$simFile = Join-Path $Root 'bench\apps\portfolio_sim\.deployed-commit'
$commits['portfolio_sim'] = if (Test-Path $simFile) { (Get-Content $simFile -Raw).Trim() } else { 'unknown' }
$live = [ordered]@{}; foreach ($k in $checks.Keys) { $live[$k] = (Get-Rows $port $siteConfig.db_password $db $db $checks[$k]) -join '' }
$manifest = [ordered]@{
    created = (Get-Date).ToString('o'); site = $Site; db_name = $db; dump_seconds = $dumpSeconds; commits = $commits
    sha256 = [ordered]@{ 'database.sql.gz' = Get-Sha "$sql.gz"; 'files.zip' = Get-Sha $filesZip; 'site_config.json' = Get-Sha (Join-Path $dest 'site_config.json') }
    files = $fileHashes; live_after_dump = $live
}
Write-Host ("dump {0:N1} MB ({1:N1} MB gz) in {2}s; files {3}" -f ((Get-Item $sql).Length / 1MB), ((Get-Item "$sql.gz").Length / 1MB), $dumpSeconds, $fileHashes.Count)

# --- 4. Restore check in a separate scratch MariaDB instance
if ($VerifyRestore) {
    $scratchDir = Join-Path 'C:\srv\portfolio\erp\scratch' "restore-$stamp"
    New-Item -ItemType Directory -Force $scratchDir | Out-Null
    $bytes = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $script:scratchPw = ([Convert]::ToBase64String($bytes) -replace '[+/=]', '')
    $data = Join-Path $scratchDir 'data'
    Invoke-Exe (Join-Path $bin 'mariadb-install-db.exe') @("--datadir=$data", "--port=$ScratchPort", "--password=$script:scratchPw") '' | Out-Null
    @"
[mysqld]
datadir=$($data.Replace('\','/'))
port=$ScratchPort
bind-address=127.0.0.1
skip-name-resolve
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
lower_case_table_names=2
innodb_buffer_pool_size=128M
innodb_flush_log_at_trx_commit=2
max_allowed_packet=256M
performance_schema=OFF
"@ | Set-Content (Join-Path $data 'my.ini') -Encoding ascii
    $script:scratchProc = Start-Process (Join-Path $bin 'mariadbd.exe') -ArgumentList "--defaults-file=`"$data\my.ini`"", '--console' -WindowStyle Hidden -PassThru `
        -RedirectStandardError (Join-Path $scratchDir 'mariadbd.err')
    try { $script:scratchProc.PriorityClass = 'BelowNormal' } catch {}
    $ready = $false
    for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
        Start-Sleep -Seconds 1
        try { Invoke-Exe (Join-Path $bin 'mariadb-admin.exe') @('-u', 'root', '-h', '127.0.0.1', '-P', "$ScratchPort", '--protocol=TCP', 'ping') $script:scratchPw | Out-Null; $ready = $true } catch {}
    }
    if (-not $ready) { throw 'scratch MariaDB did not start' }
    $restoreSql = Join-Path $scratchDir 'database.sql'
    Expand-Gzip "$sql.gz" $restoreSql
    if ((Get-Sha $restoreSql) -ne (Get-Sha $sql)) { throw 'gzip round trip changed the dump' }
    $root = @('-u', 'root', '-h', '127.0.0.1', '-P', "$ScratchPort", '--protocol=TCP')
    Invoke-Exe (Join-Path $bin 'mariadb.exe') ($root + @('-e', "CREATE DATABASE ``$db`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE USER '$db'@'%' IDENTIFIED BY '$($siteConfig.db_password)'; GRANT ALL PRIVILEGES ON ``$db``.* TO '$db'@'%'; FLUSH PRIVILEGES;")) $script:scratchPw | Out-Null
    $t1 = Get-Date
    Invoke-Exe (Join-Path $bin 'mariadb.exe') ($root + @('--default-character-set=utf8mb4', $db, '-e', "source $($restoreSql.Replace('\', '/'))")) $script:scratchPw | Out-Null
    $restoreSeconds = [int]((Get-Date) - $t1).TotalSeconds
    $restored = [ordered]@{}; foreach ($k in $checks.Keys) { $restored[$k] = (Get-Rows $ScratchPort $siteConfig.db_password $db $db $checks[$k]) -join '' }
    $problems = @()
    foreach ($k in $checks.Keys) {
        $rc = [long]($restored[$k].Split(':')[0]); $lc = [long]($live[$k].Split(':')[0])
        if ($rc -gt $lc) { $problems += "$k restored=$($restored[$k]) > live=$($live[$k])" }
        if ($rc -eq $lc -and $restored[$k] -ne $live[$k]) { $problems += "$k same count, different content: restored=$($restored[$k]) live=$($live[$k])" }
        Write-Host "  $k live=$($live[$k]) restored=$($restored[$k])"
    }
    if ([long]($restored['sim_ledger'].Split(':')[0]) -eq 0 -and [long]($live['sim_ledger'].Split(':')[0]) -gt 0) { $problems += 'restored ledger is empty' }
    # Internal consistency of the snapshot: the engine commits each event's documents, its ledger row and the
    # executed counter in one transaction, so in any consistent snapshot they agree exactly.
    $executed = (Get-Rows $ScratchPort $siteConfig.db_password $db $db "select coalesce(max(value),0) from tabSingles where doctype = 'Distribution Sim Settings' and field = 'events_executed'") -join ''
    $ledgerRows = [long]($restored['sim_ledger'].Split(':')[0])
    if ([long]$executed -ne $ledgerRows) { $problems += "restored events_executed=$executed but ledger rows=$ledgerRows" }
    Write-Host "  restored snapshot: events_executed=$executed ledger_rows=$ledgerRows"
    # Files: extract and re-hash
    $fx = Join-Path $scratchDir 'files'
    [IO.Compression.ZipFile]::ExtractToDirectory($filesZip, $fx)
    $bad = 0; foreach ($rel in $fileHashes.Keys) { if ((Get-Sha (Join-Path $fx $rel)) -ne $fileHashes[$rel]) { $bad++ } }
    if ($bad) { $problems += "$bad restored files differ" }
    $manifest['restore_check'] = [ordered]@{ restored = $restored; restore_seconds = $restoreSeconds; files_checked = $fileHashes.Count; problems = $problems }

    if ($DeepVerify -and -not $problems) {
        # Throwaway Frappe site on the restored database: the application must be able to read it and its own
        # integrity checks must pass. Reached only through this CLI (the proxy always names the real site).
        $scratchSite = Join-Path $sites "restore-check-$stamp.local"
        New-Item -ItemType Directory -Force $scratchSite, "$scratchSite\logs", "$scratchSite\locks" | Out-Null
        $cfg = $siteConfig | ConvertTo-Json | ConvertFrom-Json
        $cfg | Add-Member -Force db_port $ScratchPort; $cfg | Add-Member -Force db_host '127.0.0.1'
        [IO.File]::WriteAllText((Join-Path $scratchSite 'site_config.json'), ($cfg | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $ctl = Join-Path $PSScriptRoot 'erp-ctl.ps1'
        $siteName = Split-Path $scratchSite -Leaf
        & $ctl frappe -Root $Root -Site $siteName -LogFile (Join-Path $dest 'deep-status.log') -- portfolio-sim status
        if ($LASTEXITCODE -ne 0) { $problems += 'portfolio-sim status failed on the restore' }
        & $ctl frappe -Root $Root -Site $siteName -LogFile (Join-Path $dest 'deep-integrity.log') -- portfolio-sim integrity
        if ($LASTEXITCODE -ne 0) { $problems += 'portfolio-sim integrity failed on the restore (see deep-integrity.log)' }
        $manifest['restore_check']['deep'] = if ($problems) { 'failed' } else { 'status + integrity passed' }
        $manifest['restore_check']['problems'] = $problems
    }
    Stop-Scratch
    if ($problems) { $manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dest 'manifest.json') -Encoding utf8; throw "restore check failed: $($problems -join '; ')" }
    Write-Host "restore check OK ($restoreSeconds s restore, $($fileHashes.Count) files)"
}
Remove-Item $sql   # keep only the compressed dump
$manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dest 'manifest.json') -Encoding utf8

# --- 5. Retention
Get-ChildItem $OutDir -Directory -Filter 'erp-*' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } | Remove-Item -Recurse -Force
Stop-Transcript | Out-Null
exit 0
