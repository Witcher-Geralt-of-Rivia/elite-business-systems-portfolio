<#
.SYNOPSIS
  Nightly backup of the CRM database (pg_dump custom format) with retention and an optional restore check.

.DESCRIPTION
  Writes C:\srv\portfolio\backups\crm\crm-<yyyyMMdd-HHmmss>.dump plus a .sha256 file, deletes dumps
  older than -RetentionDays, and with -VerifyRestore restores the new dump into a scratch database,
  compares row counts of the business tables, then drops the scratch database.
  Credentials come from C:\srv\portfolio\secrets\crm-postgres.json (Administrators/SYSTEM only).
  Intended to run as SYSTEM from Task Scheduler; exits non-zero on any failure.
#>
[CmdletBinding()]
param(
    [string]$Database = 'crm',
    [string]$OutDir = 'C:\srv\portfolio\backups\crm',
    [int]$RetentionDays = 14,
    [switch]$VerifyRestore
)
$ErrorActionPreference = 'Stop'
$logDir = 'C:\srv\portfolio\logs\maintenance'
New-Item -ItemType Directory -Force $logDir | Out-Null
Start-Transcript -Path (Join-Path $logDir "backup-$Database-$(Get-Date -Format yyyyMMdd).log") -Append | Out-Null
trap { Write-Host "FAILED: $_"; Stop-Transcript | Out-Null; exit 1 }
$bin = 'C:\Program Files\PostgreSQL\16\bin'
$secret = Get-Content 'C:\srv\portfolio\secrets\crm-postgres.json' -Raw | ConvertFrom-Json
$common = @('-h', '127.0.0.1', '-p', [string]$secret.port, '-U', $secret.superuser)

# Windows PowerShell 5.1 turns any native stderr line (e.g. a NOTICE) into an error record;
# judge native tools by exit code only.
function Invoke-Pg([string]$tool, [string[]]$arguments, [switch]$Capture) {
    $ErrorActionPreference = 'Continue'
    $output = & (Join-Path $bin $tool) @common @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$tool failed ($LASTEXITCODE): $($output | Out-String)" }
    if ($Capture) { return ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n" }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$file = Join-Path $OutDir "$Database-$stamp.dump"

$env:PGPASSWORD = $secret.superuser_password
try {
    Invoke-Pg 'pg_dump.exe' @('-d', $Database, '-Fc', '-Z', '6', '-f', $file)
    $hash = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    Set-Content "$file.sha256" "$hash  $(Split-Path $file -Leaf)" -Encoding ascii
    Write-Host ("backup {0} ({1:N1} KB) sha256={2}" -f (Split-Path $file -Leaf), ((Get-Item $file).Length / 1KB), $hash.Substring(0, 16))

    if ($VerifyRestore) {
        $scratch = "${Database}_restore_check"
        Invoke-Pg 'dropdb.exe' @('--if-exists', $scratch)
        Invoke-Pg 'createdb.exe' @('-O', 'crm_owner', $scratch)
        try {
            Invoke-Pg 'pg_restore.exe' @('-d', $scratch, '--exit-on-error', $file)
            $countSql = "select string_agg(t || '=' || n, ',' order by t) from (" +
                ((@('companies', 'contacts', 'deals', 'contact_notes', 'deal_notes', 'tasks', 'sales', 'users', 'audit_log') |
                    ForEach-Object { "select '$_' as t, count(*) as n from crm.$_" }) -join ' union all ') + ") s"
            $live = Invoke-Pg 'psql.exe' @('-d', $Database, '-Atc', $countSql) -Capture
            $restored = Invoke-Pg 'psql.exe' @('-d', $scratch, '-Atc', $countSql) -Capture
            if ($live -ne $restored) { throw "restore check mismatch: live=[$live] restored=[$restored]" }
            Write-Host "restore check OK: $restored"
        } finally {
            Invoke-Pg 'dropdb.exe' @('--if-exists', $scratch)
        }
    }
} finally {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
}

Get-ChildItem $OutDir -Filter "$Database-*.dump*" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
    Remove-Item -Force
Stop-Transcript | Out-Null
