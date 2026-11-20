<#
.SYNOPSIS
  Windows services for the native ERPNext runtime (owner decision ERP-RUNTIME, 2026-11-20). Idempotent.

.DESCRIPTION
  Requires install-erp-runtime.ps1 (MariaDB service `portfolio-erp-mariadb` is created there). Installs WinSW 2
  services, all as LOCAL SERVICE, automatic start, restart on failure (10 s / 30 s / 60 s, counter reset after 1 h),
  logs under <Root>\logs\<service> rolled by size:

    portfolio-erp-redis-cache    Redis 8.10.3, 127.0.0.1:13102, no persistence (cache)
    portfolio-erp-redis-queue    Redis 8.10.3, 127.0.0.1:11102, AOF everysec + RDB (jobs, realtime pub/sub)
    portfolio-erp-web            waitress + frappe.app.application, 127.0.0.1:8851
    portfolio-erp-worker-short   FrappeWorkerNoFork (TimerDeathPenalty), queues short,default   [below normal]
    portfolio-erp-worker-long    same, queue long                                              [below normal]
    portfolio-erp-scheduler      frappe.utils.scheduler loop                                   [below normal]
    portfolio-erp-socketio       Frappe's realtime server (Node 24) pinned to 127.0.0.1:8852
    portfolio-erp-proxy          private Caddy instance (own binary copy, own config, admin API off) on
                                 127.0.0.1:8850: /assets and /files from disk, /socket.io -> 8852, rest -> 8851,
                                 X-Frappe-Site-Name set to the site. Not the host Caddy; no public listener.

  -Site names the Frappe site the proxy serves (default erp.portfolio.local).
  Uninstall: -Remove stops and deletes these services (data and code stay).
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\srv\portfolio\erp\runtime',
    [string]$Site = 'erp.portfolio.local',
    [string]$WinSW = 'C:\srv\caddy\caddy-service.exe',
    [string]$CaddySource = 'C:\srv\caddy\caddy.exe',
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [int]$ProxyPort = 8850,
    [int]$WebPort = 8851,
    [int]$SocketIOPort = 8852,
    [int]$RedisCachePort = 13102,
    [int]$RedisQueuePort = 11102,
    [string[]]$Only,
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$bench = Join-Path $Root 'bench'; $sites = Join-Path $bench 'sites'; $venvPy = Join-Path $bench 'env\Scripts\python.exe'
# On Windows a venv's python.exe is a launcher that starts the real interpreter as a CHILD process. Under the service
# wrapper that left orphaned interpreters running after a stop/restart (measured 2026-11-20: two orphaned workers kept
# consuming jobs) and made a kill hit the launcher only. The services run the base interpreter directly and set
# __PYVENV_LAUNCHER__, exactly as the launcher does, so each service is ONE process with the venv's sys.prefix.
$pyHome = ((Get-Content (Join-Path $bench 'env\pyvenv.cfg') | Where-Object { $_ -match '^home\s*=' }) -split '=', 2)[1].Trim()
$py = Join-Path $pyHome 'python.exe'
$svcDir = Join-Path $Root 'services'; $logs = Join-Path $Root 'logs'; $adapt = Join-Path $Root 'adapt'
$acct = 'NT AUTHORITY\LOCAL SERVICE'
$node = (Get-Command node.exe).Source
$deps = @('portfolio-erp-mariadb', 'portfolio-erp-redis-cache', 'portfolio-erp-redis-queue')
$pyEnv = @{ PYTHONUTF8 = '1'; PYTHONUNBUFFERED = '1'; PATH = "$Root\mariadb\bin;%PATH%"; '__PYVENV_LAUNCHER__' = $venvPy }

$services = [ordered]@{
    # The MSYS2 build resolves Windows paths with backslashes as relative POSIX paths: the config is passed relative
    # to the working directory (the instance directory), and its `dir` is `./`.
    # Ctrl+C from the service wrapper does not reach the MSYS2 process (measured: killed after the stop timeout), and a
    # redis-cli stop command launched by the wrapper did not shut it down either (stop hung; output not visible), so
    # the stop command is redis_stop.py: AUTH + SHUTDOWN with the password read from redis.conf, outcome in stop.log.
    'portfolio-erp-redis-cache' = @{ name = 'Portfolio ERP Redis (cache)'; exe = "$Root\redis\redis-server.exe"; args = 'redis.conf'; wd = "$Root\redis-cache"; prio = 'Normal'; deps = @(); stop = 20
        stopExe = $py; stopArgs = "-I `"$adapt\redis_stop.py`" `"$Root\redis-cache`""; env = @{} }
    'portfolio-erp-redis-queue' = @{ name = 'Portfolio ERP Redis (queue)'; exe = "$Root\redis\redis-server.exe"; args = 'redis.conf'; wd = "$Root\redis-queue"; prio = 'Normal'; deps = @(); stop = 30
        stopExe = $py; stopArgs = "-I `"$adapt\redis_stop.py`" `"$Root\redis-queue`""; env = @{} }
    'portfolio-erp-web' = @{ name = 'Portfolio ERP web'; exe = $py; args = "`"$adapt\serve_win.py`" 127.0.0.1:$WebPort 6"; wd = $sites; prio = 'Normal'; deps = $deps; stop = 20; env = $pyEnv }
    'portfolio-erp-scheduler' = @{ name = 'Portfolio ERP scheduler'; exe = $py; args = "`"$adapt\scheduler_win.py`""; wd = $sites; prio = 'BelowNormal'; deps = $deps; stop = 20; env = $pyEnv }
    'portfolio-erp-worker-short' = @{ name = 'Portfolio ERP worker (short, default)'; exe = $py; args = "`"$adapt\worker_win.py`" short,default"; wd = $sites; prio = 'BelowNormal'; deps = $deps; stop = 120; env = $pyEnv }
    'portfolio-erp-worker-long' = @{ name = 'Portfolio ERP worker (long)'; exe = $py; args = "`"$adapt\worker_win.py`" long"; wd = $sites; prio = 'BelowNormal'; deps = $deps; stop = 180; env = $pyEnv }
    'portfolio-erp-socketio' = @{ name = 'Portfolio ERP realtime (Socket.IO)'; exe = $node; args = "`"$adapt\realtime_win.js`""; wd = $bench; prio = 'Normal'; deps = @('portfolio-erp-redis-queue'); stop = 10
        env = @{ FRAPPE_BENCH_ROOT = $bench; NODE_PATH = "$Root\realtime\node_modules"; NODE_ENV = 'production' } }
    'portfolio-erp-proxy' = @{ name = 'Portfolio ERP private proxy'; exe = "$Root\proxy\caddy.exe"; args = "run --config `"$Root\proxy\Caddyfile`" --adapter caddyfile"; wd = "$Root\proxy"; prio = 'Normal'; deps = @(); stop = 10
        env = @{ XDG_DATA_HOME = "$Root\proxy\data"; XDG_CONFIG_HOME = "$Root\proxy\config"; HOME = "$Root\proxy" } }
}
if ($Only) { foreach ($k in @($services.Keys)) { if ($Only -notcontains $k) { $services.Remove($k) } } }

function Invoke-Native([string]$what, [scriptblock]$cmd) {
    $ErrorActionPreference = 'Continue'
    $out = & $cmd 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { $out | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }; throw "$what failed (exit $LASTEXITCODE)" }
    return $out
}
function Write-Utf8([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false)) }
function Esc([string]$s) { [Security.SecurityElement]::Escape($s) }

if ($Remove) {
    foreach ($id in ($services.Keys | Sort-Object -Descending)) {
        $exe = Join-Path $svcDir "$id.exe"
        if (Get-Service $id -ErrorAction SilentlyContinue) {
            Stop-Service $id -Force -ErrorAction SilentlyContinue
            if (Test-Path $exe) { Invoke-Native "uninstall $id" { & $exe uninstall } | Out-Null } else { sc.exe delete $id | Out-Null }
            Write-Host "removed $id"
        }
    }
    return
}

# --- Supporting files -----------------------------------------------------------------------------------------
New-Item -ItemType Directory -Force $svcDir, $logs, $adapt, "$Root\proxy\data", "$Root\proxy\config", "$Root\realtime" | Out-Null
Copy-Item (Join-Path $Repo 'scripts\erp-native\*.py'), (Join-Path $Repo 'scripts\erp-native\*.js') $adapt -Force
if ($services.Contains('portfolio-erp-proxy') -or -not (Test-Path "$Root\proxy\caddy.exe")) {
    if ((Get-Service portfolio-erp-proxy -ErrorAction SilentlyContinue).Status -eq 'Running') { Stop-Service portfolio-erp-proxy }
    Copy-Item $CaddySource "$Root\proxy\caddy.exe" -Force   # own copy: host Caddy upgrades do not touch the ERP proxy
}
$fwd = { param($p) $p.Replace('\', '/') }
Write-Utf8 "$Root\proxy\Caddyfile" @"
# Private ERPNext entry point (generated by install-erp-services.ps1). Loopback only; not the host Caddy.
{
	admin off
	auto_https off
	persist_config off
	servers {
		trusted_proxies static 127.0.0.1/32
	}
}

http://:$ProxyPort {
	bind 127.0.0.1
	encode zstd gzip
	header -Server
	log {
		output file $(& $fwd $logs)/proxy/access.log {
			roll_size 10MiB
			roll_keep 5
		}
		format json
	}

	@dist path_regexp ^/assets/[^/]+/dist/
	header @dist Cache-Control "public, max-age=31536000, immutable"

	handle /assets/* {
		root * $(& $fwd $sites)
		file_server
	}
	handle /files/* {
		root * $(& $fwd "$sites\$Site\public")
		file_server
	}
	handle /socket.io/* {
		reverse_proxy 127.0.0.1:$SocketIOPort {
			header_up X-Frappe-Site-Name $Site
			# As Frappe's production nginx template does: the engine.io polling handshake is a same-origin GET that
			# browsers send without an Origin header, and Frappe's realtime auth compares Origin with Host.
			header_up Origin {scheme}://{hostport}
		}
	}
	handle {
		reverse_proxy 127.0.0.1:$WebPort {
			header_up X-Frappe-Site-Name $Site
			transport http {
				read_timeout 300s
			}
		}
	}
}
"@
New-Item -ItemType Directory -Force "$logs\proxy" | Out-Null
icacls "$Root\proxy" /grant "${acct}:(OI)(CI)(M)" | Out-Null
Invoke-Native 'caddy validate' { & "$Root\proxy\caddy.exe" validate --config "$Root\proxy\Caddyfile" --adapter caddyfile } | Out-Null

# Realtime server dependencies: exact versions from Frappe's yarn.lock, installed apart from the source tree.
if (-not (Test-Path "$Root\realtime\node_modules\socket.io\package.json")) {
    $lock = Get-Content "$bench\apps\frappe\yarn.lock" -Raw
    $pkgs = @{}
    foreach ($name in 'socket.io', '@redis/client', 'cookie') {
        $m = [regex]::Match($lock, '(?m)^"?' + [regex]::Escape($name) + '@[^\n]*:\r?\n\s+version "([^"]+)"')
        if (-not $m.Success) { throw "$name not found in frappe yarn.lock" }
        $pkgs[$name] = $m.Groups[1].Value
    }
    Write-Utf8 "$Root\realtime\package.json" (@{ name = 'erp-realtime-deps'; private = $true; dependencies = $pkgs } | ConvertTo-Json)
    Push-Location "$Root\realtime"
    try { Invoke-Native 'npm install' { npm install --ignore-scripts --omit=dev --no-audit --no-fund } | Select-Object -Last 2 } finally { Pop-Location }
    Write-Host "  realtime deps: $(($pkgs.GetEnumerator() | ForEach-Object { "$($_.Key)@$($_.Value)" }) -join ', ')"
}

# --- Services ---------------------------------------------------------------------------------------------------
foreach ($id in $services.Keys) {
    $s = $services[$id]
    $exe = Join-Path $svcDir "$id.exe"; $xml = Join-Path $svcDir "$id.xml"
    $envXml = ($s.env.GetEnumerator() | Sort-Object Key | ForEach-Object { "  <env name=`"$($_.Key)`" value=`"$(Esc $_.Value)`"/>" }) -join "`n"
    $depXml = ($s.deps | ForEach-Object { "  <depend>$_</depend>" }) -join "`n"
    if ($s.stopExe) { $depXml += "`n  <stopexecutable>$(Esc $s.stopExe)</stopexecutable>`n  <stoparguments>$(Esc $s.stopArgs)</stoparguments>" }
    Write-Utf8 $xml @"
<!-- Generated by scripts/provisioning/install-erp-services.ps1 - edit there. -->
<service>
  <id>$id</id>
  <name>$(Esc $s.name)</name>
  <description>Elite Business Systems Portfolio ERP (native-Windows ERPNext, private): $(Esc $s.name).</description>
  <executable>$(Esc $s.exe)</executable>
  <arguments>$(Esc $s.args)</arguments>
  <workingdirectory>$(Esc $s.wd)</workingdirectory>
$envXml
  <serviceaccount>
    <domain>NT AUTHORITY</domain>
    <user>LocalService</user>
  </serviceaccount>
  <startmode>Automatic</startmode>
  <delayedAutoStart>true</delayedAutoStart>
$depXml
  <priority>$($s.prio)</priority>
  <stoptimeout>$($s.stop) sec</stoptimeout>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="restart" delay="60 sec"/>
  <resetfailure>1 hour</resetfailure>
  <logpath>$(Esc (Join-Path $logs $id))</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>5</keepFiles>
  </log>
</service>
"@
    New-Item -ItemType Directory -Force (Join-Path $logs $id) | Out-Null
    $installed = [bool](Get-Service $id -ErrorAction SilentlyContinue)
    if ($installed) { Stop-Service $id -Force -ErrorAction SilentlyContinue; (Get-Service $id).WaitForStatus('Stopped', '00:03:30') }
    # The wrapper exe stays locked for a moment after the service reports Stopped.
    for ($try = 1; ; $try++) {
        try { Copy-Item $WinSW $exe -Force -ErrorAction Stop; break }
        catch { if ($try -ge 15) { throw }; Start-Sleep -Seconds 2 }
    }
    if (-not $installed) { Invoke-Native "install $id" { & $exe install } | Out-Null }
    # A wrapper that exits with an error code is a failure for the service manager, too (not only crashes).
    Invoke-Native "failureflag $id" { sc.exe failureflag $id 1 } | Out-Null
    Write-Host "  $id installed"
}
icacls $logs /grant "${acct}:(OI)(CI)(M)" | Out-Null
icacls $svcDir /grant "${acct}:(OI)(CI)(RX)" | Out-Null
Write-Host "Services installed. Start order: redis-cache, redis-queue, web, scheduler, workers, socketio, proxy (Start-ErpServices in erp-ctl.ps1)."
