<#
.SYNOPSIS
  Deploys the repository's portfolio_sim app to the native-Windows ERPNext runtime and restarts the Python services.

.DESCRIPTION
  1. Mirrors apps/erp/portfolio_sim into <Root>\bench\apps\portfolio_sim (no __pycache__, no .git) and records the
     repository commit in .deployed-commit (suffix +uncommitted when the app has local changes).
  2. Compiles the app's bytecode (the services run as LOCAL SERVICE without write access to the code).
  3. With -Migrate: `frappe --site <site> migrate` for each -Sites entry (DocType or patch changes).
  4. Restarts web, scheduler and workers (Redis, MariaDB, Socket.IO and the proxy keep running) unless -NoRestart.
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\srv\portfolio\erp\runtime',
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string[]]$Sites = @('erp.portfolio.local'),
    [switch]$Migrate,
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
$dest = Join-Path $Root 'bench\apps\portfolio_sim'
robocopy (Join-Path $Repo 'apps\erp\portfolio_sim') $dest /MIR /XD __pycache__ .git /XF *.pyc .deployed-commit /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
$commit = (git -C $Repo rev-parse HEAD).Trim()
if (git -C $Repo status --porcelain -- apps/erp/portfolio_sim) { $commit += '+uncommitted' }
[IO.File]::WriteAllText((Join-Path $dest '.deployed-commit'), $commit, [Text.UTF8Encoding]::new($false))
$env:PYTHONUTF8 = '1'
& (Join-Path $Root 'bench\env\Scripts\python.exe') -m compileall -q (Join-Path $dest 'portfolio_sim')
if ($LASTEXITCODE -ne 0) { throw 'compileall failed' }
Write-Host "portfolio_sim deployed at $commit"
$ctl = Join-Path $PSScriptRoot '..\maintenance\erp-ctl.ps1'
if ($Migrate) {
    foreach ($s in $Sites) {
        & $ctl frappe -Root $Root -Site $s -LogFile (Join-Path $Root "logs\setup\$s-migrate.log") -- migrate
        if ($LASTEXITCODE -ne 0) { throw "migrate $s failed (see logs\setup\$s-migrate.log)" }
        Write-Host "migrated $s"
    }
}
if (-not $NoRestart) {
    foreach ($svc in 'portfolio-erp-web', 'portfolio-erp-scheduler', 'portfolio-erp-worker-short', 'portfolio-erp-worker-long') {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') { Restart-Service $svc -WarningAction SilentlyContinue; Write-Host "restarted $svc" }
    }
}
