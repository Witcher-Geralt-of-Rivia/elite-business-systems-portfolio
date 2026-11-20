<#
.SYNOPSIS
  Native-Windows runtime for ERPNext/Frappe v16.60.0 (owner decision ERP-RUNTIME, 2026-11-20). Idempotent.

.DESCRIPTION
  Builds C:\srv\portfolio\erp\runtime from SHA-256-verified downloads and the pinned upstream sources. This is a
  project-maintained compatibility adaptation, not a platform Frappe supports (see docs/runbooks/ERP_NATIVE_WINDOWS.md).

    _downloads\      verified archives (MariaDB 11.8.10, Redis 8.10.3 redis-windows MSYS2 build, uv 0.13.9)
    uv\ python\      uv and the uv-managed CPython 3.14.10
    mariadb\ db\     MariaDB binaries and a dedicated data directory (127.0.0.1:3408, lower_case_table_names=2)
    redis\           Redis binaries; redis-cache\ and redis-queue\ hold each instance's config and data
    bench\apps\      frappe + erpnext (pinned clones, core.autocrlf=false, commit verified) and portfolio_sim
    bench\env\       venv with editable installs (as bench does); mysqlclient built against libmariadb
    bench\sites\     apps.txt, common_site_config.json, assets\ (installed by install-erp-assets.ps1)
    adapt\           the runtime adaptations from scripts/erp-native (no upstream file is changed)
    logs\            service and database logs

  Secrets (generated here, never printed): C:\srv\portfolio\secrets\erp-runtime.json (Administrators/SYSTEM):
  MariaDB root password and the Redis password. The service account (LOCAL SERVICE) reads the Redis password only
  through common_site_config.json and the Redis configs, which are ACL-restricted.
  Nothing listens on a public interface. Windows services: install-erp-services.ps1.
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\srv\portfolio\erp\runtime',
    [string]$DownloadSource = 'C:\srv\portfolio\erp\native-spike\dl',
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [int]$DbPort = 3408,
    [int]$RedisCachePort = 13102,
    [int]$RedisQueuePort = 11102,
    [int]$WebPort = 8851,
    [int]$SocketIOPort = 8852,
    [string]$DbService = 'portfolio-erp-mariadb'
)
$ErrorActionPreference = 'Stop'
$pins = @{
    frappe = @{ tag = 'v16.60.0'; sha = 'bf9581a7c1c8c373c2ab514a404e9094609381ee'; url = 'https://github.com/frappe/frappe' }
    erpnext = @{ tag = 'v16.60.0'; sha = '886ab6ae187244e7f1b852393384ab6019d56264'; url = 'https://github.com/frappe/erpnext' }
}
$downloads = @{
    # mariadb.org archive sha256sums.txt
    'mariadb.zip' = '05d04b46763ea3dc9111bfc82dc061e0a158c682a73d31ba34b13f2653c88d17'
    # redis-windows/redis-windows release 8.10.3 (asset digest + release notes; built by its Actions run 40432509982)
    'redis.zip' = 'af16df340525b431e9ec8dabfd625d5e7a233f82805b5418819904ea909c447f'
    # astral-sh/uv 0.13.9 release .sha256
    'uv-x86_64-pc-windows-msvc.zip' = 'edd61f7f5728a56cc62455386661860bdfc7bab65872f39b0c25bdcc1d8e1beb'
}
$pythonVersion = '3.14.10'
$acct = 'NT AUTHORITY\LOCAL SERVICE'
$secretFile = 'C:\srv\portfolio\secrets\erp-runtime.json'
$dl = Join-Path $Root '_downloads'; $bench = Join-Path $Root 'bench'; $envDir = Join-Path $bench 'env'
$py = Join-Path $envDir 'Scripts\python.exe'; $uv = Join-Path $Root 'uv\uv.exe'
$maria = Join-Path $Root 'mariadb'; $data = Join-Path $Root 'db'; $logs = Join-Path $Root 'logs'

function Invoke-Native([string]$what, [scriptblock]$cmd) {
    $ErrorActionPreference = 'Continue'
    $out = & $cmd 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { $out | Select-Object -Last 30 | ForEach-Object { Write-Host "  $_" }; throw "$what failed (exit $LASTEXITCODE)" }
    return $out
}
function New-Secret([int]$len = 32) {
    $bytes = New-Object byte[] $len
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ([Convert]::ToBase64String($bytes) -replace '[+/=]', '').Substring(0, $len)
}
function Write-Ascii([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false)) }
function Step([string]$name) { Write-Host "== $name ($(Get-Date -Format HH:mm:ss))" }

New-Item -ItemType Directory -Force $Root, $dl, $bench, $logs, "$bench\apps", "$bench\sites", "$bench\logs", "$bench\config\pids" | Out-Null

# --- 1. Verified downloads ---------------------------------------------------------------------------
Step 'downloads'
foreach ($name in $downloads.Keys) {
    $target = Join-Path $dl $name
    if (-not (Test-Path $target)) { Copy-Item (Join-Path $DownloadSource $name) $target }
    $hash = (Get-FileHash $target -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $downloads[$name]) { Remove-Item $target; throw "$name SHA-256 mismatch: $hash" }
    Write-Host "  $name sha256 ok"
}
function Expand-Once([string]$zip, [string]$dest, [string]$probe) {
    if (Test-Path (Join-Path $dest $probe)) { return }
    $tmp = Join-Path $Root "_x_$([IO.Path]::GetFileNameWithoutExtension($zip))"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive (Join-Path $dl $zip) $tmp -Force
    $inner = Get-ChildItem $tmp
    $src = if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) { $inner[0].FullName } else { $tmp }
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Move-Item $src $dest
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
}
Expand-Once 'mariadb.zip' $maria 'bin\mariadbd.exe'
Expand-Once 'redis.zip' (Join-Path $Root 'redis') 'redis-server.exe'
Expand-Once 'uv-x86_64-pc-windows-msvc.zip' (Join-Path $Root 'uv') 'uv.exe'

# --- 2. Secrets ---------------------------------------------------------------------------------------
if (Test-Path $secretFile) { $secret = Get-Content $secretFile -Raw | ConvertFrom-Json }
else {
    $secret = [pscustomobject]@{ db_root_password = New-Secret; redis_password = New-Secret; admin_password = New-Secret 20 }
    Write-Ascii $secretFile ($secret | ConvertTo-Json)
}

# --- 3. Python 3.14 (uv) and the pinned sources --------------------------------------------------------
Step 'python + sources'
$env:UV_PYTHON_INSTALL_DIR = Join-Path $Root 'python'
$env:UV_CACHE_DIR = Join-Path $Root 'uv-cache'
$env:UV_PYTHON_DOWNLOADS = 'manual'
Invoke-Native 'uv python install' { & $uv python install --no-bin $pythonVersion } | Select-Object -Last 2
if (-not (Test-Path $py)) { Invoke-Native 'uv venv' { & $uv venv --python $pythonVersion --seed $envDir } | Out-Null }

foreach ($app in 'frappe', 'erpnext') {
    $dir = Join-Path $bench "apps\$app"
    if (-not (Test-Path "$dir\.git")) {
        Invoke-Native "clone $app" { git -c core.autocrlf=false clone -q --depth 1 --branch $pins[$app].tag $pins[$app].url $dir } | Out-Null
        git -C $dir config core.autocrlf false
    }
    $head = (git -C $dir rev-parse HEAD).Trim()
    if ($head -ne $pins[$app].sha) { throw "$app is at $head, expected $($pins[$app].sha)" }
    $dirty = git -C $dir status --porcelain --untracked-files=no
    if ($dirty) { throw "$app working tree differs from the pinned commit:`n$($dirty | Select-Object -First 5)" }
    Write-Host "  $app $($pins[$app].tag) $head clean"
}
# portfolio_sim: the repository's app (deployed copy, not a link to the working tree)
robocopy (Join-Path $Repo 'apps\erp\portfolio_sim') (Join-Path $bench 'apps\portfolio_sim') /MIR /XD __pycache__ .git /XF *.pyc /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy portfolio_sim failed ($LASTEXITCODE)" }
$simCommit = (git -C $Repo rev-parse HEAD).Trim()
if (git -C $Repo status --porcelain -- apps/erp/portfolio_sim) { $simCommit += '+uncommitted' }
Write-Ascii (Join-Path $bench 'apps\portfolio_sim\.deployed-commit') $simCommit
Write-Ascii (Join-Path $bench 'sites\apps.txt') "frappe`nerpnext`nportfolio_sim`n"

# --- 4. Python packages (editable, as bench installs apps) ------------------------------------------------
Step 'python packages'
$connector = Join-Path $Root 'build\connector'
if (-not (Test-Path "$connector\lib\mariadbclient.lib")) {
    New-Item -ItemType Directory -Force "$connector\include", "$connector\lib" | Out-Null
    Copy-Item "$maria\include\mysql" "$connector\include\" -Recurse -Force
    # mysqlclient links "mariadbclient"; the static library needs zlib, so link the DLL's import library instead.
    Copy-Item "$maria\lib\libmariadb.lib" "$connector\lib\mariadbclient.lib" -Force
    Copy-Item "$maria\lib\libmariadb.dll" "$connector\lib\" -Force
}
$env:MYSQLCLIENT_CONNECTOR = $connector
Invoke-Native 'uv pip install' {
    & $uv pip install --python $py -e "$bench\apps\frappe" -e "$bench\apps\erpnext" -e "$bench\apps\portfolio_sim" `
        'waitress==3.0.2' 'unittest-xml-reporting==4.0.0'
} | Select-Object -Last 3
$site = Join-Path $envDir 'Lib\site-packages'
Copy-Item "$maria\lib\libmariadb.dll" "$site\MySQLdb\" -Force
Copy-Item (Join-Path $Repo 'scripts\erp-native\site-packages\*.py') $site -Force
New-Item -ItemType Directory -Force (Join-Path $Root 'adapt') | Out-Null
Copy-Item (Join-Path $Repo 'scripts\erp-native\*.py') (Join-Path $Root 'adapt') -Force
Copy-Item (Join-Path $Repo 'scripts\erp-native\*.js') (Join-Path $Root 'adapt') -Force -ErrorAction SilentlyContinue
$env:PYTHONUTF8 = '1'
Invoke-Native 'import check' { & $py -c "import MySQLdb, frappe, erpnext, portfolio_sim, waitress; print('MySQLdb', MySQLdb.get_client_info(), 'frappe', frappe.__version__, 'erpnext', erpnext.__version__)" }
# The services run as LOCAL SERVICE without write access to the code: compile the bytecode now.
Invoke-Native 'compileall' { & $py -m compileall -q -j 2 "$bench\apps\frappe\frappe" "$bench\apps\erpnext\erpnext" "$bench\apps\portfolio_sim\portfolio_sim" (Join-Path $Root 'adapt') $site } | Out-Null

# --- 5. MariaDB (dedicated instance) ------------------------------------------------------------------------
Step 'mariadb'
if (-not (Test-Path "$data\mysql")) {
    Invoke-Native 'mariadb-install-db' { & "$maria\bin\mariadb-install-db.exe" "--datadir=$data" "--port=$DbPort" "--password=$($secret.db_root_password)" } | Out-Null
}
$fwd = { param($p) $p.Replace('\', '/') }
Write-Ascii "$data\my.ini" @"
[mysqld]
datadir=$(& $fwd $data)
port=$DbPort
bind-address=127.0.0.1
skip-name-resolve
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
# Frappe looks tables up by exact mixed-case name (tabDefaultValue); the Windows default (1) lower-cases them.
lower_case_table_names=2
innodb_buffer_pool_size=384M
innodb_log_file_size=96M
innodb_flush_log_at_trx_commit=1
max_allowed_packet=256M
max_connections=60
table_open_cache=2000
performance_schema=OFF
log_error=$(& $fwd $logs)/mariadb.err
[client]
port=$DbPort
default-character-set=utf8mb4
plugin-dir=$(& $fwd $maria)/lib/plugin
"@
foreach ($p in @($Root)) { icacls $p /grant "${acct}:(OI)(CI)(RX)" | Out-Null }
foreach ($p in @($data, $logs, "$bench\sites", "$bench\logs", "$bench\config")) { icacls $p /grant "${acct}:(OI)(CI)(M)" | Out-Null }
# The verified archives and build inputs stay administrator-only.
icacls $dl /inheritance:r /grant 'BUILTIN\Administrators:(OI)(CI)(F)' 'NT AUTHORITY\SYSTEM:(OI)(CI)(F)' | Out-Null
if (-not (Get-Service $DbService -ErrorAction SilentlyContinue)) {
    Invoke-Native 'service install' { & "$maria\bin\mariadbd.exe" --install $DbService "--defaults-file=$data\my.ini" } | Out-Null
    Invoke-Native 'service config' { sc.exe config $DbService obj= 'NT AUTHORITY\LocalService' start= auto DisplayName= 'Portfolio ERP MariaDB' } | Out-Null
    Invoke-Native 'service description' { sc.exe description $DbService 'Elite Business Systems Portfolio: dedicated MariaDB 11.8 for ERPNext on 127.0.0.1 (not shared with POS/CRM).' } | Out-Null
    Invoke-Native 'service recovery' { sc.exe failure $DbService reset= 3600 actions= restart/10000/restart/30000/restart/60000 } | Out-Null
}
if ((Get-Service $DbService).Status -ne 'Running') { Start-Service $DbService; (Get-Service $DbService).WaitForStatus('Running', '00:01:00') }
$env:MYSQL_PWD = $secret.db_root_password
try {
    $v = Invoke-Native 'db check' { & "$maria\bin\mariadb.exe" -u root -h 127.0.0.1 -P $DbPort --protocol=TCP -N -e "DELETE FROM mysql.global_priv WHERE User = ''; FLUSH PRIVILEGES; SELECT CONCAT(VERSION(), ' lctn=', @@lower_case_table_names, ' bind=', @@bind_address)" }
    Write-Host "  MariaDB $v"
} finally { Remove-Item Env:MYSQL_PWD }

# --- 6. Redis configs (two loopback instances: cache without persistence, queue with AOF) -------------------
Step 'redis'
foreach ($r in @(
        @{ name = 'redis-cache'; port = $RedisCachePort; extra = "save `"`"`nappendonly no`nmaxmemory 192mb`nmaxmemory-policy allkeys-lru" },
        @{ name = 'redis-queue'; port = $RedisQueuePort; extra = "save 900 1`nsave 300 100`nappendonly yes`nappendfsync everysec`nmaxmemory-policy noeviction" })) {
    $dir = Join-Path $Root $r.name
    New-Item -ItemType Directory -Force $dir | Out-Null
    Write-Ascii "$dir\redis.conf" @"
# $($r.name) for ERPNext only (generated by install-erp-runtime.ps1)
bind 127.0.0.1
protected-mode yes
port $($r.port)
requirepass $($secret.redis_password)
dir ./
dbfilename dump.rdb
logfile ""
loglevel notice
databases 4
$($r.extra)
"@
    icacls $dir /inheritance:r /grant 'BUILTIN\Administrators:(OI)(CI)(F)' 'NT AUTHORITY\SYSTEM:(OI)(CI)(F)' "${acct}:(OI)(CI)(M)" | Out-Null
}

# --- 7. Bench configuration -----------------------------------------------------------------------------------
Step 'bench config'
$pw = $secret.redis_password
$common = [ordered]@{
    db_host = '127.0.0.1'; db_port = $DbPort; db_type = 'mariadb'
    redis_cache = "redis://:$pw@127.0.0.1:$RedisCachePort"
    redis_queue = "redis://:$pw@127.0.0.1:$RedisQueuePort"
    redis_socketio = "redis://:$pw@127.0.0.1:$RedisQueuePort"
    socketio_port = $SocketIOPort; webserver_port = $WebPort; webserver_host = '127.0.0.1'
    serve_default_site = $true; live_reload = $false; restart_supervisor_on_update = $false
    background_workers = 1; file_watcher_port = 0; developer_mode = 0
}
$commonFile = Join-Path $bench 'sites\common_site_config.json'
if (Test-Path $commonFile) {
    $existing = Get-Content $commonFile -Raw | ConvertFrom-Json
    foreach ($p in $existing.PSObject.Properties) { if (-not $common.Contains($p.Name)) { $common[$p.Name] = $p.Value } }
}
Write-Ascii $commonFile ($common | ConvertTo-Json)
icacls $commonFile /inheritance:r /grant 'BUILTIN\Administrators:(F)' 'NT AUTHORITY\SYSTEM:(F)' "${acct}:(R)" | Out-Null

Step 'done'
Write-Host "ERP runtime ready under $Root (Python $pythonVersion, MariaDB on 127.0.0.1:$DbPort as $DbService)."
Write-Host "Next: install-erp-services.ps1 (Redis, web, workers, scheduler, Socket.IO, proxy), then new-erp-site.ps1."
