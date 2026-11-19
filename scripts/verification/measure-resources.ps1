<#
.SYNOPSIS
  Read-only resource and latency measurement of the hosted applications (portfolio + co-hosted services).

.DESCRIPTION
  - Host CPU (sampled every 5 s over -Minutes), RAM, disk free.
  - Per-service CPU share (CPU-seconds consumed during the window / wall time) and working set, including
    child processes (php-cgi under WinSW, postgres backends, ...).
  - Disk use of the POS installation, its data directory and backups.
  - HTTP latency (median and p95 of -Requests sequential requests) for loopback POS pages and the public
    CRM/portal/co-hosted endpoints. No IP addresses in the output (host names are masked).
#>
[CmdletBinding()]
param([int]$Minutes = 5, [int]$Requests = 20, [string]$PublicIp = $env:PUBLIC_IP)
$ErrorActionPreference = 'Stop'
if (-not $PublicIp) { $PublicIp = (Select-String -Path C:\srv\portfolio\caddy\crm.caddy -Pattern 'crm\.(\d+\.\d+\.\d+\.\d+)\.sslip').Matches[0].Groups[1].Value }
$services = @('caddy', 'portfolio-crm-api', 'portfolio-crm-postgres', 'portfolio-pos-mariadb', 'portfolio-pos-php-1', 'portfolio-pos-php-2', 'portfolio-pos-sim')
# The co-hosted application's identifiers live only on the host, not in this public repository.
$coCfg = if (Test-Path 'C:\srv\portfolio\config\cohosted.json') { Get-Content 'C:\srv\portfolio\config\cohosted.json' -Raw | ConvertFrom-Json } else { $null }
if ($coCfg) { $services += @(Get-Service | Where-Object { $n = $_.Name; @($coCfg.service_patterns | Where-Object { $n -like $_ }).Count } | ForEach-Object Name) }

function Get-Tree([int]$root) {
    $all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId
    $ids = @($root); $frontier = @($root)
    while ($frontier) { $frontier = @($all | Where-Object { $frontier -contains $_.ParentProcessId } | ForEach-Object { $_.ProcessId }); $ids += $frontier }
    return $ids
}
function Get-Usage {
    $r = @{}
    foreach ($s in $services) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$s'" -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.ProcessId -eq 0) { continue }
        $procs = Get-Process -Id (Get-Tree $svc.ProcessId) -ErrorAction SilentlyContinue
        $r[$s] = [pscustomobject]@{ Cpu = ($procs | Measure-Object CPU -Sum).Sum; Ws = ($procs | Measure-Object WorkingSet64 -Sum).Sum; Count = @($procs).Count; Start = $svc.StartMode; State = $svc.State }
    }
    return $r
}

$t0 = Get-Date; $u0 = Get-Usage
$cpu = @(); $end = $t0.AddMinutes($Minutes)
while ((Get-Date) -lt $end) { $cpu += (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 5 -MaxSamples 1).CounterSamples[0].CookedValue }
$u1 = Get-Usage; $wall = ((Get-Date) - $t0).TotalSeconds
$os = Get-CimInstance Win32_OperatingSystem
$sorted = $cpu | Sort-Object
$out = [ordered]@{
    window_minutes = [math]::Round($wall / 60, 1)
    host = [ordered]@{
        cpu_avg_pct = [math]::Round(($cpu | Measure-Object -Average).Average, 1)
        cpu_p95_pct = [math]::Round($sorted[[int][math]::Floor(0.95 * ($sorted.Count - 1))], 1)
        ram_used_gb = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
        ram_total_gb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        disk_c_free_gb = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    }
    services = [ordered]@{}
}
foreach ($s in $services) {
    if (-not $u1.ContainsKey($s)) { $out.services[$s] = 'not running'; continue }
    $c0 = if ($u0.ContainsKey($s)) { $u0[$s].Cpu } else { 0 }
    $out.services[$s] = [ordered]@{ state = $u1[$s].State; start = $u1[$s].Start; processes = $u1[$s].Count
        ram_mb = [int]($u1[$s].Ws / 1MB); cpu_core_pct = [math]::Round(100 * ($u1[$s].Cpu - $c0) / $wall, 1) }
}
$sizes = [ordered]@{}
foreach ($p in 'C:\srv\portfolio\pos\app', 'C:\srv\portfolio\pos\mariadb', 'C:\srv\portfolio\backups\pos', 'C:\srv\portfolio\pos\php', 'C:\srv\portfolio\crm') {
    if (Test-Path $p) { $sizes[$p] = [math]::Round(((Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB, 1) }
}
$out.disk_mb = $sizes

$targets = [ordered]@{}
if (Test-Path 'C:\srv\portfolio\caddy\pos.public-enabled') {
    # Public POS (D-017): the loopback listener only serves the health route.
    $targets['pos public /sign-in'] = "https://pos.$PublicIp.sslip.io/sign-in"
    $targets['pos public /harborpine/health'] = "https://pos.$PublicIp.sslip.io/harborpine/health"
    $targets['portal public /status/pos'] = "https://portfolio.$PublicIp.sslip.io/status/pos"
} else {
    $targets['pos loopback /sign-in'] = 'http://127.0.0.1:8820/sign-in'
}
$targets['pos loopback /harborpine/health'] = 'http://127.0.0.1:8820/harborpine/health'
$targets['crm public /api/health'] = "https://crm.$PublicIp.sslip.io/api/health"
$targets['crm public /'] = "https://crm.$PublicIp.sslip.io/"
$targets['portal public /healthz'] = "https://portfolio.$PublicIp.sslip.io/healthz"
if ($coCfg -and $coCfg.url) { $targets['co-hosted application'] = $coCfg.url }
$lat = [ordered]@{}
foreach ($k in $targets.Keys) {
    $times = @(); $codes = @{}
    for ($i = 0; $i -lt $Requests; $i++) {
        $r = (& curl.exe -s -o NUL -m 60 -w '%{http_code} %{time_total}' $targets[$k]) -split ' '
        $codes[$r[0]] = 1 + [int]$codes[$r[0]]; $times += [double]$r[1]
    }
    $ts = $times | Sort-Object
    $lat[$k] = [ordered]@{ status = ($codes.Keys -join ','); median_ms = [int](1000 * $ts[[int][math]::Floor(($ts.Count - 1) / 2)]); p95_ms = [int](1000 * $ts[[int][math]::Floor(0.95 * ($ts.Count - 1))]); max_ms = [int](1000 * $ts[-1]) }
}
$out.latency = $lat
$out | ConvertTo-Json -Depth 5
