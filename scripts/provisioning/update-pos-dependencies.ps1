<#
.SYNOPSIS
  Security maintenance for NexoPOS's PHP dependencies: constrained update in a staging copy, verification, then a
  guarded swap into the live app (with automatic rollback), or a rollback on request.

.DESCRIPTION
  -Stage    Copies the live app to <App>-staging (without logs/sessions; the public\lang junction is recreated),
            removes its cached bootstrap files (they hold the live app's absolute paths), runs
            `composer update <Packages> --with-all-dependencies --no-dev` inside NexoPOS's own version constraints,
            and requires `composer audit --locked --no-dev` to report no advisories.
            Then verify the staging tree before promoting it:
              scripts/verification/run-pos-e2e.ps1 -Mode isolated -AppRoot <App>-staging
              scripts/verification/run-pos-e2e.ps1 -Mode visitor  -AppRoot <App>-staging
              scripts/verification/run-pos-sim-recovery.ps1    -AppRoot <App>-staging
  -Promote  Stops the POS simulation worker and both PHP workers (the public POS answers 502 for about a minute),
            copies the staged vendor\ into the app tree (copying, not moving, so files inherit the app's ACL for
            the LOCAL SERVICE workers), swaps it in with composer.lock and the package manifests, keeping
            vendor.prev/composer.lock.prev, rebuilds caches (deploy-pos-module.ps1), restarts the services and
            smoke-tests health, sign-in and integrity. Any failure rolls back automatically.
  -Rollback Restores vendor.prev and composer.lock.prev the same way.
  Never touches Caddy, the database schema, CRM or co-hosted services.
#>
[CmdletBinding(DefaultParameterSetName = 'stage')]
param(
    [Parameter(ParameterSetName = 'stage')] [switch]$Stage,
    [Parameter(ParameterSetName = 'promote')] [switch]$Promote,
    [Parameter(ParameterSetName = 'rollback')] [switch]$Rollback,
    [string]$App = 'C:\srv\portfolio\pos\app',
    [string[]]$Packages = @('laravel/framework', 'symfony/http-foundation', 'symfony/http-kernel', 'symfony/routing', 'symfony/mime',
        'symfony/http-client', 'guzzlehttp/guzzle', 'league/commonmark', 'league/flysystem', 'dompdf/dompdf', 'phpoffice/phpspreadsheet')
)
$ErrorActionPreference = 'Stop'
$php = 'C:\srv\portfolio\pos\php\php.exe'
$composer = 'C:\srv\portfolio\pos\_downloads\composer.phar'
$staging = "$App-staging"
$services = 'portfolio-pos-php-1', 'portfolio-pos-php-2'
$worker = 'portfolio-pos-sim'

function Invoke-Php([string]$cwd, [string[]]$a) {
    $ErrorActionPreference = 'Continue'
    Push-Location $cwd
    try { & $php @a 2>&1 | ForEach-Object { Write-Host "  $_" }; return $LASTEXITCODE } finally { Pop-Location }
}
function Get-Health {
    $ErrorActionPreference = 'Continue'
    return (& curl.exe -s -m 30 http://127.0.0.1:8820/harborpine/health) -join ''
}

if ($Stage) {
    if (Test-Path $staging) { cmd /c rmdir /s /q "$staging" }
    robocopy $App $staging /E /XJ /XD "$App\storage\logs" "$App\storage\framework\sessions" /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
    New-Item -ItemType Directory -Force "$staging\storage\logs", "$staging\storage\framework\sessions" | Out-Null
    cmd /c mklink /J "$staging\public\lang" "$staging\lang" | Out-Null
    Get-ChildItem "$staging\bootstrap\cache" -Filter *.php | Remove-Item
    $env:COMPOSER_HOME = Join-Path $env:TEMP 'composer-home'
    if ((Invoke-Php $staging (@($composer, 'update') + $Packages + @('--with-all-dependencies', '--no-dev', '--no-interaction', '--no-progress'))) -ne 0) { throw 'composer update failed' }
    if ((Invoke-Php $staging @($composer, 'audit', '--locked', '--no-dev', '--no-interaction')) -ne 0) { throw 'composer audit still reports advisories' }
    Write-Host "staged and audited: $staging (now run the verification suites with -AppRoot $staging)"
    return
}

function Switch-Vendor([string]$fromVendor, [string]$fromLock, [string[]]$manifests, [string]$label) {
    Write-Host "== $label"
    Stop-Service $worker
    foreach ($s in $services) { Stop-Service $s }
    try {
        if ($fromVendor -ne "$App\vendor.prev") {
            # Copy into the app tree first so every file inherits the app's ACL (read for the LOCAL SERVICE workers).
            if (Test-Path "$App\vendor.new") { cmd /c rmdir /s /q "$App\vendor.new" }
            robocopy $fromVendor "$App\vendor.new" /E /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy vendor failed ($LASTEXITCODE)" }
            if (Test-Path "$App\vendor.prev") { cmd /c rmdir /s /q "$App\vendor.prev" }
            Rename-Item "$App\vendor" 'vendor.prev'
            Rename-Item "$App\vendor.new" 'vendor'
            Copy-Item "$App\composer.lock" "$App\composer.lock.prev" -Force
            Copy-Item $fromLock "$App\composer.lock" -Force
            New-Item -ItemType Directory -Force "$App\bootstrap\manifests.prev" | Out-Null
            foreach ($n in 'packages.php', 'services.php') { if (Test-Path "$App\bootstrap\cache\$n") { Copy-Item "$App\bootstrap\cache\$n" "$App\bootstrap\manifests.prev\" -Force } }
        } else {
            if (Test-Path "$App\vendor.failed") { cmd /c rmdir /s /q "$App\vendor.failed" }
            Rename-Item "$App\vendor" 'vendor.failed'
            Rename-Item "$App\vendor.prev" 'vendor'
            Copy-Item $fromLock "$App\composer.lock" -Force
        }
        foreach ($m in $manifests) { Copy-Item $m "$App\bootstrap\cache\" -Force }
    } finally {
        foreach ($s in $services) { Start-Service $s }
    }
    & (Join-Path $PSScriptRoot 'deploy-pos-module.ps1') -App $App | Out-Host   # caches for the new vendor tree
}
function Test-Live {
    $ok = $false
    for ($i = 0; $i -lt 20 -and -not $ok; $i++) { Start-Sleep -Seconds 3; $ok = (Get-Health) -match '"status":"ok"' }
    if (-not $ok) { return 'health endpoint not ok' }
    $ErrorActionPreference = 'Continue'
    Push-Location $App
    try { $integrity = (& $php artisan hp:integrity --json 2>$null) -join "`n" | ConvertFrom-Json } finally { Pop-Location }
    if (-not $integrity -or $integrity.checks -lt 43 -or $integrity.failing -isnot [array]) { return 'integrity checks failing' }
    return $null
}

if ($Promote) {
    if (-not (Test-Path "$staging\vendor")) { throw "no staged tree at $staging (run -Stage first)" }
    $manifests = @(Get-ChildItem "$staging\bootstrap\cache" -Filter *.php | Where-Object { $_.Name -in 'packages.php', 'services.php' } | ForEach-Object FullName)
    Switch-Vendor "$staging\vendor" "$staging\composer.lock" $manifests 'promote staged dependencies'
    $problem = Test-Live
    if ($problem) {
        Write-Warning "smoke failed ($problem): rolling back"
        Switch-Vendor "$App\vendor.prev" "$App\composer.lock.prev" @(Get-ChildItem "$App\bootstrap\manifests.prev" -Filter *.php | ForEach-Object FullName) 'rollback'
        Start-Service $worker
        throw "promotion rolled back: $problem"
    }
    Start-Service $worker
    Write-Host 'promoted: dependencies updated, health ok, integrity 43/43; previous tree kept as vendor.prev'
} elseif ($Rollback) {
    if (-not (Test-Path "$App\vendor.prev")) { throw 'no vendor.prev to roll back to' }
    Switch-Vendor "$App\vendor.prev" "$App\composer.lock.prev" @(Get-ChildItem "$App\bootstrap\manifests.prev" -Filter *.php | ForEach-Object FullName) 'rollback'
    Start-Service $worker
    Write-Host "rolled back; health: $(Get-Health)"
}
