<#
.SYNOPSIS
  Read-only health monitor for the portfolio (CRM, POS, portal), run every 15 minutes as SYSTEM.

.DESCRIPTION
  Checks, each independently (one failing check never hides the others):
    - public HTTPS health: CRM /api/health, POS /harborpine/health (database, worker running, lag),
      portal /healthz, /status/crm and (while the POS is public) /status/pos;
    - TLS certificate lifetime of each public host (Caddy renews automatically; < 14 days means renewal failed);
    - portfolio Windows services running;
    - latest CRM/POS backup younger than 26 h with its .sha256 file, and the backup tasks' last result 0;
    - free space on C: (R-004 alarm threshold 3 GB).
  Every run appends one JSON line to C:\srv\portfolio\logs\monitor-<yyyyMM>.jsonl (12 months kept). When a check
  changes state (fails or recovers), an entry is written to the Windows Application event log, source
  "PortfolioMonitor" (event 1001 = failing, 1000 = recovered), so problems show up without any paid service.
  Nothing is restarted or changed; output never contains the host address.
#>
[CmdletBinding()]
param(
    [string]$PublicIp = $env:PUBLIC_IP,
    [int]$MaxWorkerLagSeconds = 900,
    [int]$MinCertDays = 14,
    [int]$MaxBackupAgeHours = 26,
    [double]$MinFreeGb = 3
)
$ErrorActionPreference = 'Stop'
$logDir = 'C:\srv\portfolio\logs'
$stateFile = Join-Path $logDir 'monitor-state.json'
if (-not $PublicIp) { $PublicIp = (Select-String -Path C:\srv\portfolio\caddy\crm.caddy -Pattern 'crm\.(\d+\.\d+\.\d+\.\d+)\.sslip').Matches[0].Groups[1].Value }
$posPublic = Test-Path 'C:\srv\portfolio\caddy\pos.public-enabled'
$results = [ordered]@{}

function Add-Result([string]$name, [bool]$ok, [string]$detail) {
    $script:results[$name] = [ordered]@{ ok = $ok; detail = ($detail -replace '\d+\.\d+\.\d+\.\d+', '<VPS_IP>') }
}
function Get-Url([string]$url) {
    $ErrorActionPreference = 'Continue'
    $out = & curl.exe -s -m 30 -w "`n%{http_code}" $url 2>$null
    $lines = @($out)
    return [pscustomobject]@{ Code = [string]$lines[-1]; Body = (($lines | Select-Object -SkipLast 1) -join "`n") }
}
function Test-Check([string]$name, [scriptblock]$check) {
    try { & $check } catch { Add-Result $name $false "check error: $($_.Exception.Message)" }
}

# Public health
Test-Check 'crm.health' {
    $r = Get-Url "https://crm.$PublicIp.sslip.io/api/health"
    Add-Result 'crm.health' ($r.Code -eq '200' -and $r.Body -match '"status":"ok"') "HTTP $($r.Code)"
}
if ($posPublic) {
    Test-Check 'pos.health' {
        $r = Get-Url "https://pos.$PublicIp.sslip.io/harborpine/health"
        $h = $r.Body | ConvertFrom-Json
        $sim = $h.simulation
        $ok = $r.Code -eq '200' -and $h.status -eq 'ok' -and $h.database -and ($sim.paused -or ($sim.worker_running -and $sim.lag_seconds -le $MaxWorkerLagSeconds))
        Add-Result 'pos.health' $ok "HTTP $($r.Code); worker_running=$($sim.worker_running) paused=$($sim.paused) lag=$($sim.lag_seconds)s"
    }
}
Test-Check 'portal.health' {
    $paths = @('/healthz', '/status/crm') + @(if ($posPublic) { '/status/pos' })
    $bad = @(foreach ($p in $paths) { $c = (Get-Url "https://portfolio.$PublicIp.sslip.io$p").Code; if ($c -ne '200') { "$p=$c" } })
    Add-Result 'portal.health' ($bad.Count -eq 0) $(if ($bad) { $bad -join ', ' } else { "$($paths.Count) routes 200" })
}

# TLS certificate lifetime
foreach ($sub in @('crm', 'portfolio') + @(if ($posPublic) { 'pos' })) {
    Test-Check "tls.$sub" {
        $h = "$sub.$PublicIp.sslip.io"
        $tcp = New-Object Net.Sockets.TcpClient($h, 443)
        try {
            $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, { $true })
            $ssl.AuthenticateAsClient($h)
            $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
            $days = [int]($cert.NotAfter - (Get-Date)).TotalDays
            $chain = (New-Object Security.Cryptography.X509Certificates.X509Chain).Build($cert)
            Add-Result "tls.$sub" ($days -ge $MinCertDays -and $chain) "expires in $days days; chain valid=$chain"
        } finally { $tcp.Dispose() }
    }
}

# Services
Test-Check 'services' {
    $names = 'portfolio-crm-api', 'portfolio-crm-postgres', 'portfolio-pos-mariadb', 'portfolio-pos-php-1', 'portfolio-pos-php-2', 'portfolio-pos-sim', 'caddy'
    $down = @(foreach ($n in $names) { $s = Get-Service $n -ErrorAction SilentlyContinue; if (-not $s -or $s.Status -ne 'Running') { "$n=$(if ($s) { $s.Status } else { 'missing' })" } })
    Add-Result 'services' ($down.Count -eq 0) $(if ($down) { $down -join ', ' } else { "$($names.Count) running" })
}

# Backups
foreach ($b in @(@{ app = 'crm'; filter = 'crm-*.dump'; task = 'Portfolio - CRM nightly backup' }, @{ app = 'pos'; filter = 'pos-*.sql'; task = 'Portfolio - POS nightly backup' })) {
    Test-Check "backup.$($b.app)" {
        $latest = Get-ChildItem "C:\srv\portfolio\backups\$($b.app)" -Filter $b.filter -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $info = Get-ScheduledTask -TaskName $b.task -ErrorAction SilentlyContinue | Get-ScheduledTaskInfo
        if (-not $latest) { Add-Result "backup.$($b.app)" $false 'no backup found'; return }
        $age = [math]::Round(((Get-Date) - $latest.LastWriteTime).TotalHours, 1)
        $sha = Test-Path "$($latest.FullName).sha256"
        $taskOk = $info -and $info.LastTaskResult -eq 0
        Add-Result "backup.$($b.app)" ($age -le $MaxBackupAgeHours -and $sha -and $taskOk) "latest $age h old; sha256=$sha; task result=$(if ($info) { $info.LastTaskResult } else { 'missing' })"
    }
}

# Disk
Test-Check 'disk.c' {
    $free = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    Add-Result 'disk.c' ($free -ge $MinFreeGb) "$free GB free (alarm below $MinFreeGb GB)"
}

# Log line, state transitions, event log
$failing = @($results.Keys | Where-Object { -not $results[$_].ok })
$record = [ordered]@{ time = (Get-Date).ToString('o'); ok = ($failing.Count -eq 0); failing = $failing; checks = $results }
New-Item -ItemType Directory -Force $logDir | Out-Null
Add-Content -Path (Join-Path $logDir ("monitor-{0:yyyyMM}.jsonl" -f (Get-Date))) -Value ($record | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8
Get-ChildItem $logDir -Filter 'monitor-*.jsonl' | Sort-Object Name -Descending | Select-Object -Skip 12 | Remove-Item

$previous = @{}
if (Test-Path $stateFile) { (Get-Content $stateFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $previous[$_.Name] = [bool]$_.Value } }
$current = [ordered]@{}; foreach ($k in $results.Keys) { $current[$k] = [bool]$results[$k].ok }
$source = 'PortfolioMonitor'
$canLog = [Diagnostics.EventLog]::SourceExists($source)
foreach ($k in $current.Keys) {
    $was = if ($previous.ContainsKey($k)) { $previous[$k] } else { $true }
    if ($was -ne $current[$k] -and $canLog) {
        $id = if ($current[$k]) { 1000 } else { 1001 }
        $type = if ($current[$k]) { 'Information' } else { 'Error' }
        Write-EventLog -LogName Application -Source $source -EventId $id -EntryType $type -Message "$k $(if ($current[$k]) { 'recovered' } else { 'FAILING' }): $($results[$k].detail)"
    }
}
$current | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
Write-Host "monitor: $(if ($failing) { 'FAILING ' + ($failing -join ', ') } else { 'all ' + $results.Count + ' checks ok' })"
if ($failing) { exit 1 }
