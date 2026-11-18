<#
.SYNOPSIS
  Deploys the portfolio portal (portal/site) to C:\srv\portfolio\portal\www and refreshes the portal's Caddy site.

.DESCRIPTION
  1. Stages a copy of portal/site and writes config.js from the host state:
       crm  = live      when the portfolio-crm-api service is running, otherwise "preparing";
       pos  = live      only when the owner-approval flag C:\srv\portfolio\caddy\pos.public-enabled exists;
       erp  = planned.
  2. Swaps the staged copy in (the previous site is kept as www.prev-<stamp>, the last 3 are retained).
  3. Renders the Caddy site files (render-caddy-sites.ps1: whole host Caddyfile validated, then a graceful
     `caddy reload`; the Caddy service is never restarted and the host Caddyfile is not modified).
  4. Smoke-tests the public site; on any failure the previous site is restored and Caddy re-rendered.
  The /status/pos route only exists while the POS approval flag exists (template @if-flag block).
#>
[CmdletBinding()]
param([string]$PublicIp = $env:PUBLIC_IP, [string]$Root = 'C:\srv\portfolio\portal')
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
if (-not $PublicIp) { $PublicIp = (Select-String -Path C:\srv\portfolio\caddy\crm.caddy -Pattern 'crm\.(\d+\.\d+\.\d+\.\d+)\.sslip').Matches[0].Groups[1].Value }
$hostName = "portfolio.$PublicIp.sslip.io"
$www = Join-Path $Root 'www'
$stage = Join-Path $Root 'www.new'
$stamp = Get-Date -Format yyyyMMdd-HHmmss
$prev = Join-Path $Root "www.prev-$stamp"
$render = Join-Path $PSScriptRoot 'render-caddy-sites.ps1'

# 1. stage
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
robocopy (Join-Path $repo 'portal\site') $stage /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
$crm = if ((Get-Service portfolio-crm-api -ErrorAction SilentlyContinue).Status -eq 'Running') { 'live' } else { 'preparing' }
$pos = if (Test-Path 'C:\srv\portfolio\caddy\pos.public-enabled') { 'live' } else { 'preparing' }
$config = @"
// Written by scripts/provisioning/deploy-portal.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm').
window.PORTAL_CONFIG = {
  apps: { crm: "$crm", pos: "$pos", erp: "planned" },
  repo: "https://github.com/Witcher-Geralt-of-Rivia/elite-business-systems-portfolio",
};
"@
[IO.File]::WriteAllText((Join-Path $stage 'config.js'), $config, (New-Object Text.UTF8Encoding $false))
Write-Host "staged portal (crm=$crm, pos=$pos)"

# 2. swap
if (Test-Path $www) { Rename-Item $www $prev }
Rename-Item $stage $www

function Restore-Previous([string]$why) {
    Write-Warning "rolling back: $why"
    if (Test-Path $prev) {
        if (Test-Path $www) { Remove-Item $www -Recurse -Force }
        Rename-Item $prev $www
    }
    & $render -PublicIp $PublicIp | Out-Host
}

try {
    # 3. Caddy site files (validate + graceful reload)
    & $render -PublicIp $PublicIp | Out-Host

    # 4. smoke tests
    $fail = @()
    $get = { param($path) $ErrorActionPreference = 'Continue'; (& curl.exe -s -m 20 -D - -o NUL -w '%{http_code}' "https://$hostName$path") -join "`n" }
    $front = & $get '/'
    if ($front -notmatch '200$') { $fail += "/ -> $($front.Substring([Math]::Max(0, $front.Length - 3)))" }
    if ($front -notmatch '(?im)^content-security-policy:') { $fail += 'no CSP header' }
    $cfg = (& curl.exe -s -m 20 "https://$hostName/config.js") -join "`n"
    if ($cfg -notmatch "crm: `"$crm`"" -or $cfg -notmatch "pos: `"$pos`"") { $fail += 'config.js not served as written' }
    $status = (& curl.exe -s -m 20 "https://$hostName/status/crm") -join ''
    if ($crm -eq 'live' -and $status -notmatch '"status":"ok"') { $fail += "status/crm: $status" }
    $posCode = (& curl.exe -s -m 20 -o NUL -w '%{http_code}' "https://$hostName/status/pos")
    if ($pos -ne 'live' -and $posCode -ne '404') { $fail += "status/pos should be 404 while private (got $posCode)" }
    foreach ($a in 'assets/portal.css', 'assets/portal.js', 'assets/shots/crm.jpg', 'assets/shots/pos.jpg') {
        $c = (& curl.exe -s -m 20 -o NUL -w '%{http_code}' "https://$hostName/$a")
        if ($c -ne '200') { $fail += "$a -> $c" }
    }
    if ($fail) { throw ($fail -join '; ') }
} catch {
    Restore-Previous "$_"
    throw
}
Get-ChildItem $Root -Directory -Filter 'www.prev-*' | Sort-Object Name -Descending | Select-Object -Skip 3 | Remove-Item -Recurse -Force
Write-Host "portal deployed: https://portfolio.<VPS_IP>.sslip.io (crm=$crm, pos=$pos); /status/crm ok; /status/pos $posCode"
