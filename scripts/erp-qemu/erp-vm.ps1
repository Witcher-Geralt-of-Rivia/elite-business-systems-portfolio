<#
.SYNOPSIS
  ERPNext proof of concept: a headless Debian 13 guest under QEMU with TCG software emulation (no WSL, no Hyper-V,
  no Windows feature, no reboot).

.DESCRIPTION
  Everything lives under -Root (default C:\srv\portfolio\erp\qemu-poc) and is removable with -Action cleanup:
    qemu\        QEMU for Windows extracted from the official installer (never installed or registered)
    downloads\   verified installer and Debian cloud image (base image, read-only backing file)
    vm\          erp.qcow2 (dynamically allocated overlay on the base image), seed\ (cloud-init), ssh\ (key pair)
    logs\        serial console, QEMU stderr, watchdog CSV

  Isolation: software CPU emulation only (-accel tcg); user-mode networking with loopback-only forwards (SSH, the
  ERPNext web port, QMP control); no public listener, no Caddy route; QEMU runs at BelowNormal priority so
  production services win any CPU contention.

  Actions:
    init     create the key pair, the overlay disk and the cloud-init seed (refuses to overwrite an existing disk)
    start    boot the guest (first boot serves the cloud-init seed on loopback for the guest only)
    status   process, CPU time, memory, disk growth, SSH reachability
    stop     clean ACPI shutdown through QMP; waits up to -TimeoutSec
    kill     hard stop (QMP quit, then process termination) - for recovery tests and emergencies
    ssh      run -Command in the guest (or print the ssh command line)
    cleanup  stop the guest, remove the scheduled task, delete vm\ and logs\ (-All also deletes qemu\, tools\ and
             downloads\)
  QEMU is started by the on-demand scheduled task 'Portfolio - ERP QEMU guest' (SYSTEM, below-normal priority, no
  trigger), never as a child of the calling console.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('init', 'start', 'status', 'stop', 'kill', 'ssh', 'cleanup')][string]$Action,
    [string]$Root = 'C:\srv\portfolio\erp\qemu-poc',
    [int]$MemoryMB = 2048,
    [int]$Cpus = 1,
    [string]$CpuModel = 'max',
    [int]$TbSizeMB = 256,
    [int]$SshPort = 2290,
    [int]$WebPort = 8830,
    [int]$QmpPort = 8831,
    [int]$SeedPort = 8832,
    [string]$DiskSize = '40G',
    [string]$BaseImage = 'debian-13-genericcloud-amd64.qcow2',
    [string]$Command,
    [int]$TimeoutSec = 180,
    [switch]$All
)
$ErrorActionPreference = 'Stop'
$qemuDir = Join-Path $Root 'qemu'; $vmDir = Join-Path $Root 'vm'; $logDir = Join-Path $Root 'logs'
$disk = Join-Path $vmDir 'erp.qcow2'; $key = Join-Path $vmDir 'ssh\id_ed25519'; $pidFile = Join-Path $vmDir 'qemu.pid'
$seedDir = Join-Path $vmDir 'seed'; $seededMarker = Join-Path $vmDir 'seeded'
$taskName = 'Portfolio - ERP QEMU guest'

function Invoke-Native([string]$exe, [string[]]$arguments) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $exe @arguments 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0) { throw "$exe exited $LASTEXITCODE`n$($out -join "`n")" }
    return $out
}
function Get-Vm {
    if (-not (Test-Path $pidFile)) { return $null }
    $p = Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'qemu-system-x86_64') { return $p } else { return $null }
}
function Send-Qmp([string]$execute) {
    $c = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $QmpPort)
    try {
        $s = $c.GetStream(); $r = [System.IO.StreamReader]::new($s); $w = [System.IO.StreamWriter]::new($s); $w.AutoFlush = $true
        $null = $r.ReadLine()                                   # greeting
        $w.WriteLine('{"execute":"qmp_capabilities"}'); $null = $r.ReadLine()
        $w.WriteLine("{`"execute`":`"$execute`"}"); return $r.ReadLine()
    } finally { $c.Close() }
}
function Test-Port([int]$port) {
    $c = [System.Net.Sockets.TcpClient]::new()
    try { return $c.ConnectAsync('127.0.0.1', $port).Wait(1000) -and $c.Connected } catch { return $false } finally { $c.Close() }
}
function Invoke-Guest([string]$cmd, [int]$connectTimeout = 10) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        & ssh.exe -i $key -p $SshPort -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o LogLevel=ERROR `
            -o ConnectTimeout=$connectTimeout -o BatchMode=yes erp@127.0.0.1 $cmd
    } finally { $ErrorActionPreference = $old }
}

switch ($Action) {
    'init' {
        if (Test-Path $disk) { throw "$disk exists; use -Action cleanup first" }
        $base = Join-Path $Root "downloads\$BaseImage"
        if (-not (Test-Path $base)) { throw "base image missing: $base" }
        New-Item -ItemType Directory -Force (Split-Path $key), $seedDir, $logDir | Out-Null
        if (-not (Test-Path $key)) { Invoke-Native 'ssh-keygen.exe' @('-q', '-t', 'ed25519', '-N', '""', '-C', 'erp-poc', '-f', $key) | Out-Null }
        # ssh.exe refuses private keys that other principals can read.
        Invoke-Native 'icacls.exe' @($key, '/inheritance:r', '/grant:r', "$($env:USERNAME):F", 'SYSTEM:F') | Out-Null
        Set-ItemProperty $base -Name IsReadOnly -Value $true
        Invoke-Native (Join-Path $qemuDir 'qemu-img.exe') @('create', '-q', '-f', 'qcow2', '-F', 'qcow2', '-b', $base, $disk, $DiskSize) | Out-Null
        $pub = (Get-Content "$key.pub" -Raw).Trim()
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $seedDir 'meta-data'), "instance-id: erp-poc-1`nlocal-hostname: erp-poc`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $seedDir 'vendor-data'), "", $utf8)
        [IO.File]::WriteAllText((Join-Path $seedDir 'user-data'), @"
#cloud-config
hostname: erp-poc
timezone: UTC
users:
  - name: erp
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys: ["$pub"]
ssh_pwauth: false
package_update: false
package_upgrade: false
swap:
  filename: /swapfile
  size: 1073741824
runcmd:
  - [systemctl, disable, --now, apt-daily.timer, apt-daily-upgrade.timer, man-db.timer, e2scrub_all.timer, fstrim.timer]
  - [touch, /etc/cloud/cloud-init.disabled]
"@.Replace("`r`n", "`n"), $utf8)
        Write-Host "initialised $disk (backing $base, virtual $DiskSize); seed in $seedDir"
    }
    'start' {
        if (Get-Vm) { Write-Host "already running (pid $((Get-Vm).Id))"; return }
        if (-not (Test-Path $disk)) { throw "no disk; run -Action init" }
        foreach ($p in $SshPort, $WebPort, $QmpPort) { if (Test-Port $p) { throw "loopback port $p is already in use" } }
        New-Item -ItemType Directory -Force $logDir | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $qargs = @(
            # SMM off: with SMM enabled (q35 or pc) the SeaBIOS boot loops in System Management Mode under TCG (measured: no
            # kernel output after 10 minutes, CPU in SMM in the BIOS segment).
            '-name', 'erp-poc', '-machine', 'pc,smm=off', '-accel', "tcg,thread=single,tb-size=$TbSizeMB", '-cpu', $CpuModel,
            '-smp', "$Cpus", '-m', "$MemoryMB", '-rtc', 'base=utc',
            '-drive', "file=$disk,if=virtio,format=qcow2,cache=writeback,discard=unmap,detect-zeroes=unmap",
            '-netdev', "user,id=n0,hostfwd=tcp:127.0.0.1:$SshPort-:22,hostfwd=tcp:127.0.0.1:$WebPort-:8000",
            '-device', 'virtio-net-pci,netdev=n0', '-device', 'virtio-rng-pci',
            '-display', 'none', '-vga', 'none', '-serial', "file:$logDir\serial-$stamp.log",
            '-qmp', "tcp:127.0.0.1:$QmpPort,server=on,wait=off"
        )
        $seedServer = $null
        if (-not (Test-Path $seededMarker)) {
            # First boot only: cloud-init NoCloud fetches its seed from the host loopback (10.0.2.2 inside the guest).
            if (Test-Port $SeedPort) { throw "seed port $SeedPort in use" }
            $seedServer = Start-Process python.exe -ArgumentList '-m', 'http.server', "$SeedPort", '--bind', '127.0.0.1', '--directory', $seedDir `
                -WindowStyle Hidden -PassThru -RedirectStandardError "$logDir\seed-http-$stamp.log"
            $qargs += '-smbios', "type=1,serial=ds=nocloud;s=http://10.0.2.2:$SeedPort/"
        }
        Remove-Item $pidFile -ErrorAction SilentlyContinue
        $qargs += '-pidfile', $pidFile
        # Launched by Task Scheduler (SYSTEM, no time limit, below-normal priority) so QEMU belongs to no console or
        # session: closing the calling shell, terminal or agent session must not take the guest down. (Measured: a
        # child of the agent shell died with it; a process started through WMI Win32_Process.Create exited when its
        # WMI provider host was recycled ~27 minutes later.)
        $quoted = ($qargs | ForEach-Object { if ($_ -match '[\s;&]') { "`"$_`"" } else { $_ } }) -join ' '
        $launcher = Join-Path $vmDir 'launch.cmd'
        [IO.File]::WriteAllText($launcher, "@echo off`r`n`"$(Join-Path $qemuDir 'qemu-system-x86_64.exe')`" $quoted 1>>`"$logDir\qemu-$stamp.log`" 2>&1`r`n", [System.Text.Encoding]::ASCII)
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority 7 -MultipleInstances IgnoreNew `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable:$false
        $taskAction = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c `"$launcher`"" -WorkingDirectory $vmDir
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Settings $settings -Principal $principal -Force `
            -Description 'ERPNext proof of concept: QEMU-TCG Debian guest (scripts/erp-qemu/erp-vm.ps1). Loopback only.' | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $t = Get-Date
        while (-not (Get-Vm)) {
            if (((Get-Date) - $t).TotalSeconds -gt 20) { throw "QEMU did not start: $(Get-Content "$logDir\qemu-$stamp.log" -Raw -ErrorAction SilentlyContinue)" }
            Start-Sleep -Milliseconds 500
        }
        $p = Get-Vm
        $p.PriorityClass = 'BelowNormal'
        Write-Host "started pid $($p.Id) (tcg, cpu $CpuModel, $Cpus vCPU, $MemoryMB MB, BelowNormal); serial log $logDir\serial-$stamp.log"
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec * 5) {
            if ($p.HasExited) { throw "QEMU exited during boot" }
            $o = Invoke-Guest 'cloud-init status 2>/dev/null || true; cat /proc/uptime' 5
            if ($LASTEXITCODE -eq 0) {
                if ($seedServer -and ($o -join ' ') -notmatch 'status: (done|error|disabled)') { Start-Sleep 10; continue }
                Write-Host ("guest ready after {0:N0} s: {1}" -f ((Get-Date) - $t0).TotalSeconds, ($o -join ' | '))
                if ($seedServer) { Stop-Process -Id $seedServer.Id -ErrorAction SilentlyContinue; Set-Content $seededMarker (Get-Date -Format o) }
                return
            }
            Start-Sleep 10
        }
        throw "guest did not become reachable over SSH within $($TimeoutSec * 5) s (QEMU still running, pid $($p.Id))"
    }
    'status' {
        $p = Get-Vm
        $diskMB = if (Test-Path $disk) { [int]((Get-Item $disk).Length / 1MB) } else { 0 }
        if (-not $p) { [pscustomobject]@{ running = $false; disk_mb = $diskMB } | Format-List; return }
        $p.Refresh()
        [pscustomobject]@{
            running = $true; pid = $p.Id; priority = $p.PriorityClass; started = $p.StartTime
            cpu_seconds = [int]$p.CPU; working_set_mb = [int]($p.WorkingSet64 / 1MB); private_mb = [int]($p.PrivateMemorySize64 / 1MB)
            disk_mb = $diskMB; ssh = (Test-Port $SshPort); web = (Test-Port $WebPort)
        } | Format-List
    }
    'stop' {
        $p = Get-Vm; if (-not $p) { Write-Host 'not running'; return }
        Write-Host (Send-Qmp 'system_powerdown')
        if ($p.WaitForExit($TimeoutSec * 1000)) { Remove-Item $pidFile -ErrorAction SilentlyContinue; Write-Host "guest shut down cleanly" }
        else { throw "guest did not shut down within $TimeoutSec s; use -Action kill" }
    }
    'kill' {
        $p = Get-Vm; if (-not $p) { Write-Host 'not running'; return }
        try { $null = Send-Qmp 'quit' } catch { }
        if (-not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force }
        Remove-Item $pidFile -ErrorAction SilentlyContinue; Write-Host "QEMU terminated (pid $($p.Id))"
    }
    'ssh' {
        if ($Command) { Invoke-Guest $Command; exit $LASTEXITCODE }
        Write-Host "ssh -i `"$key`" -p $SshPort -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL erp@127.0.0.1"
    }
    'cleanup' {
        if (Get-Vm) { try { & $PSCommandPath -Action stop -Root $Root -QmpPort $QmpPort } catch { & $PSCommandPath -Action kill -Root $Root -QmpPort $QmpPort } }
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; Write-Host "removed task $taskName" }
        foreach ($d in @($vmDir, $logDir) + $(if ($All) { @($qemuDir, (Join-Path $Root 'tools'), (Join-Path $Root 'downloads')) } else { @() })) {
            if (Test-Path $d) {
                Get-ChildItem $d -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
                Remove-Item $d -Recurse -Force; Write-Host "removed $d"
            }
        }
    }
}
