<#
.SYNOPSIS
  Runs the CRM browser tests against the PUBLIC deployment, then removes what they created and verifies
  that no test account can sign in. Admin credentials are read from the restricted secrets folder.
#>
param(
    [Parameter(Mandatory)] [string]$PublicIp,
    [string]$Spec = 'e2e-portfolio/crm-showcase.spec.ts e2e-portfolio/crm-poc.spec.ts e2e-portfolio/crm-m4.spec.ts'
)
$ErrorActionPreference = 'Continue'
$admin = Get-Content C:\srv\portfolio\secrets\crm-admin-account.json -Raw | ConvertFrom-Json
$env:CRM_E2E_BASE_URL = "https://crm.$PublicIp.sslip.io"
$env:CRM_E2E_EMAIL = $admin.email
$env:CRM_E2E_PASSWORD = $admin.password
$env:CRM_E2E_REUSE_INVITEE = '1'
Push-Location (Join-Path $PSScriptRoot '..\..\apps\crm\frontend')
$args2 = $Spec -split ' '
npx playwright test -c playwright.portfolio.config.ts @args2 $env:PW_EXTRA 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^\s+at ' }
"playwright exit=$LASTEXITCODE"
Pop-Location
Remove-Item Env:CRM_E2E_PASSWORD

# Remove what the browser tests created in production (they use a per-run marker) and make sure
# no test account can sign in afterwards.
$sql = @'
update users set password_hash = null where email like 'new.rep.%@meridian-advisory.example' or email = 'e2e.invitee@meridian-advisory.example';
update sales set disabled = true where email like 'new.rep.%@meridian-advisory.example' or email = 'e2e.invitee@meridian-advisory.example';
delete from sessions where user_id in (select id from users where email like 'new.rep.%@meridian-advisory.example' or email = 'e2e.invitee@meridian-advisory.example');
delete from contacts where last_name like 'Merge%' and first_name = 'Ingrid';
delete from contact_notes where text like 'Site visit summary %' or text like 'Live note from a teammate %' or text like 'Duplicate history %';
delete from companies where name like 'Halvorsen Maritime Analytics %';
select (select count(*) from users u join sales s on s.user_id = u.id where (s.email like 'new.rep.%' or s.email = 'e2e.invitee@meridian-advisory.example') and u.password_hash is not null) as loginable_test_accounts;
'@
$cleanup = Join-Path $env:TEMP 'crm-e2e-cleanup.mjs'
@"
import pg from 'file:///$((Resolve-Path 'C:\srv\portfolio\crm\api\node_modules\pg\lib\index.js').Path.Replace('\','/'))';
const c = new pg.Client({ connectionString: process.env.CRM_DATABASE_URL }); await c.connect();
await c.query('set search_path = crm');
const r = await c.query(process.argv[2]); const last = Array.isArray(r) ? r[r.length-1] : r;
console.log('cleanup', JSON.stringify(last.rows)); await c.end();
"@ | Set-Content $cleanup -Encoding utf8
node --env-file=C:\srv\portfolio\secrets\crm-api.env $cleanup $sql 2>&1 | ForEach-Object { "$_" }
Remove-Item $cleanup
