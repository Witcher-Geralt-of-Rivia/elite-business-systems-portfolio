<#
.SYNOPSIS
  Installs the ERPNext/Frappe production front-end assets built on Linux by .github/workflows/erp-assets.yml.

.DESCRIPTION
  1. Downloads the `erp-assets` artifact of GitHub Actions run -RunId (gh CLI) into <Root>\_assets\<RunId>.
  2. Verifies the archive's SHA-256, and that the artifact was built from exactly the commits checked out in
     <Root>\bench\apps\frappe and \erpnext (refuses otherwise: asset hashes must match the running code).
  3. Extracts the build outputs into the bench (they are git-ignored paths inside the app trees and real files under
     sites\assets) and re-hashes EVERY file against the manifest.
  4. Recreates Frappe's asset links (sites\assets\<app> -> apps\<app>\<app>\public) as directory junctions.
  5. With -ClearCache: clears the site cache (the bench caches assets.json in Redis) and restarts the web service.
  The pinned app working trees stay clean (git status shows no tracked change).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][long]$RunId,
    [string]$Root = 'C:\srv\portfolio\erp\runtime',
    [string]$Repo = 'Witcher-Geralt-of-Rivia/elite-business-systems-portfolio',
    [switch]$ClearCache
)
$ErrorActionPreference = 'Stop'
$bench = Join-Path $Root 'bench'
$dl = Join-Path $Root "_assets\$RunId"
if (-not (Test-Path "$dl\manifest.json")) {
    New-Item -ItemType Directory -Force $dl | Out-Null
    gh run download $RunId -R $Repo -n erp-assets -D $dl
    if ($LASTEXITCODE -ne 0) { throw "gh run download failed ($LASTEXITCODE)" }
}
$expected = ((Get-Content "$dl\erp-assets.tar.gz.sha256" -Raw) -split '\s+')[0].ToLower()
$actual = (Get-FileHash "$dl\erp-assets.tar.gz" -Algorithm SHA256).Hash.ToLower()
if ($expected -ne $actual) { throw "archive SHA-256 mismatch: $actual (expected $expected)" }
$manifest = Get-Content "$dl\manifest.json" -Raw | ConvertFrom-Json
foreach ($app in 'frappe', 'erpnext') {
    $head = (git -C (Join-Path $bench "apps\$app") rev-parse HEAD).Trim()
    if ($head -ne $manifest.$app) { throw "$app checkout is $head but the assets were built from $($manifest.$app)" }
}
Write-Host "artifact ok: frappe $($manifest.frappe.Substring(0,10)), erpnext $($manifest.erpnext.Substring(0,10)), portfolio_sim repo $($manifest.portfolio_sim_repo_commit.Substring(0,10)); archive sha256 $($actual.Substring(0,16))"

# Extract (Windows' bsdtar). Only paths listed in the manifest may be in the archive.
$listed = @{}; foreach ($p in $manifest.files.PSObject.Properties) { $listed[$p.Name] = $p.Value }
$entries = & tar.exe -tzf "$dl\erp-assets.tar.gz"
$unknown = @($entries | Where-Object { $_ -and -not $_.EndsWith('/') -and -not $listed.ContainsKey($_) })
if ($unknown) { throw "archive has entries outside the manifest: $($unknown | Select-Object -First 5)" }
if (@($entries | Where-Object { $_ -match '(^|/)\.\.(/|$)' -or $_ -match '^[/\\]' -or $_ -match '^[A-Za-z]:' })) { throw 'archive has unsafe paths' }

# Remove the previous build outputs of these apps (stale hashed bundles) before extracting the new set.
foreach ($app in Get-Content (Join-Path $bench 'sites\apps.txt')) {
    $dist = Join-Path $bench "apps\$app\$app\public\dist"
    if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
}
& tar.exe -xzf "$dl\erp-assets.tar.gz" -C $bench
if ($LASTEXITCODE -ne 0) { throw "tar extract failed ($LASTEXITCODE)" }

# Re-hash every file.
$bad = @()
foreach ($rel in $listed.Keys) {
    $p = Join-Path $bench ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $p)) { $bad += "missing $rel"; continue }
    if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() -ne $listed[$rel]) { $bad += "hash $rel" }
}
if ($bad) { throw "$($bad.Count) asset files failed verification: $($bad | Select-Object -First 5)" }
Write-Host "$($listed.Count) files extracted and verified"

# Junctions for Frappe's symlinks (sites/assets/<app> -> apps/<app>/<app>/public).
foreach ($pair in $manifest.symlinks) {
    $link = Join-Path $bench ($pair[0] -replace '/', '\')
    $target = Join-Path $bench ($pair[1] -replace '/', '\')
    if (-not (Test-Path $target)) { Write-Host "  skip link $($pair[0]) (target $($pair[1]) not present)"; continue }
    $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType) { $item.Delete() } elseif ($item) { throw "$link exists and is not a link" }
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    Write-Host "  junction $($pair[0]) -> $($pair[1])"
}
foreach ($app in 'frappe', 'erpnext') {
    $dirty = git -C (Join-Path $bench "apps\$app") status --porcelain --untracked-files=no
    if ($dirty) { throw "$app tracked files changed by the asset install: $($dirty | Select-Object -First 3)" }
}
[IO.File]::WriteAllText((Join-Path $bench 'sites\assets\.installed-from'), "run $RunId sha256 $actual`n", [Text.UTF8Encoding]::new($false))
if ($ClearCache) {
    & (Join-Path $PSScriptRoot '..\maintenance\erp-ctl.ps1') frappe -- clear-cache
    Restart-Service portfolio-erp-web
}
Write-Host "assets installed from run $RunId"
