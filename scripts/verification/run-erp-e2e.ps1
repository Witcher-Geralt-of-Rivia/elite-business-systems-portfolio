<#
.SYNOPSIS
  Runs the ERPNext browser tests (apps/erp/e2e, Playwright/Chromium) against the private entry point.

.DESCRIPTION
  Ensures the restricted test user (Sales User only) exists with a fresh random password, passes the Administrator
  and test-user passwords to Playwright through the environment only, and runs the specs. Business data is only
  read; the single draft document a spec creates is deleted by the spec. The test user is disabled afterwards.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:8850',
    [string]$Site = 'erp.portfolio.local',
    [string[]]$Spec
)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$ctl = Join-Path $repo 'scripts\maintenance\erp-ctl.ps1'
$secret = Get-Content 'C:\srv\portfolio\secrets\erp-runtime.json' -Raw | ConvertFrom-Json
$viewer = 'e2e.viewer@sableridge.example'
$bytes = New-Object byte[] 18; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$viewerPw = 'Vw-' + ([Convert]::ToBase64String($bytes) -replace '[+/=]', '')
$log = Join-Path $env:TEMP 'erp-e2e-user.log'

# Create the user once (Sales User only), then set a fresh password and enable it for this run.
& $ctl frappe -Site $Site -LogFile $log -- add-user $viewer --first-name E2E --last-name Viewer --user-type 'System User' --add-role 'Sales User' | Out-Null
& $ctl frappe -Site $Site -LogFile $log -- set-password $viewer $viewerPw
if ($LASTEXITCODE -ne 0) { Get-Content $log | Select-Object -Last 10; throw 'set-password failed' }
& $ctl frappe -Site $Site -LogFile $log -- execute frappe.client.set_value --kwargs "{'doctype':'User','name':'$viewer','fieldname':'enabled','value':1}" | Out-Null

$env:ERP_E2E_BASE_URL = $BaseUrl
$env:ERP_E2E_ADMIN_PASSWORD = $secret.admin_password
$env:ERP_E2E_VIEWER_USER = $viewer
$env:ERP_E2E_VIEWER_PASSWORD = $viewerPw
Push-Location (Join-Path $repo 'apps\erp\e2e')
try {
    $env:FORCE_COLOR = '0'
    $pwArgs = @('playwright', 'test') + @($Spec | Where-Object { $_ })
    $ErrorActionPreference = 'Continue'   # npx writes warnings to stderr
    & npx.cmd @pwArgs 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch "NO_COLOR' env is ignored|--trace-warnings" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
} finally {
    Pop-Location
    Remove-Item Env:ERP_E2E_ADMIN_PASSWORD, Env:ERP_E2E_VIEWER_PASSWORD -ErrorAction SilentlyContinue
    & $ctl frappe -Site $Site -LogFile $log -- execute frappe.client.set_value --kwargs "{'doctype':'User','name':'$viewer','fieldname':'enabled','value':0}" | Out-Null
}
exit $code
