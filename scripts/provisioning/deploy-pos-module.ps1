<#
.SYNOPSIS
  Copies the HarborPine NexoPOS module into the POS app, enables it, runs its migrations and refreshes
  Laravel caches. Idempotent. Does not touch the public proxy configuration.
#>
[CmdletBinding()]
param([string]$App = 'C:\srv\portfolio\pos\app')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$php = 'C:\srv\portfolio\pos\php\php.exe'
function Invoke-Artisan([string[]]$a) {
    $ErrorActionPreference = 'Continue'
    Push-Location $App
    try { & $php artisan @a 2>&1 | ForEach-Object { Write-Host "  $_" }; if ($LASTEXITCODE -ne 0) { throw "artisan $($a -join ' ') failed ($LASTEXITCODE)" } }
    finally { Pop-Location }
}
robocopy (Join-Path $repo 'apps\pos\modules\HarborPine') (Join-Path $App 'modules\HarborPine') /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
icacls (Join-Path $App 'modules') /grant 'NT AUTHORITY\LOCAL SERVICE:(OI)(CI)(RX)' | Out-Null
# Static assets (catalog artwork) are published as a plain directory instead of NexoPOS's junction, so the
# web server reads them with the permissions it already has on public\ (NexoPOS skips linking when it exists).
robocopy (Join-Path $repo 'apps\pos\modules\HarborPine\Public') (Join-Path $App 'public\modules\harborpine') /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy (public assets) failed ($LASTEXITCODE)" }
Invoke-Artisan @('optimize:clear')
Invoke-Artisan @('modules:enable', 'HarborPine')
Invoke-Artisan @('modules:migrate', 'HarborPine')
Invoke-Artisan @('optimize')
Write-Host 'HarborPine module deployed'
