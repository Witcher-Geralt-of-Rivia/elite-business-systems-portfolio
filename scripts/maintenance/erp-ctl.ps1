<#
.SYNOPSIS
  Operate the native-Windows ERPNext installation: services, Frappe CLI, health.

.EXAMPLE
  erp-ctl.ps1 status                       # services, PIDs, memory, health endpoint
  erp-ctl.ps1 start | stop | restart       # all ERP services in dependency order
  erp-ctl.ps1 frappe -- portfolio-sim status          # Frappe CLI on the site (below-normal priority)
  erp-ctl.ps1 frappe -NoSite -- --version
  erp-ctl.ps1 health                       # GET /api/method/portfolio_sim.health.status through the private proxy

.NOTES
  Frappe CLI runs as the calling administrator with PYTHONUTF8=1 and the runtime adaptations (frappe_win.py), from
  the bench's sites directory, at BELOW NORMAL priority so production applications keep precedence. Files it
  creates inherit the sites directory ACL (LOCAL SERVICE: modify).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('start', 'stop', 'restart', 'status', 'frappe', 'health')][string]$Command,
    [string]$Root = 'C:\srv\portfolio\erp\runtime',
    [string]$Site = 'erp.portfolio.local',
    [int]$ProxyPort = 8850,
    [switch]$NoSite,
    [string]$LogFile,
    [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
$order = 'portfolio-erp-mariadb', 'portfolio-erp-redis-cache', 'portfolio-erp-redis-queue', 'portfolio-erp-web', 'portfolio-erp-scheduler',
'portfolio-erp-worker-short', 'portfolio-erp-worker-long', 'portfolio-erp-socketio', 'portfolio-erp-proxy'
$bench = Join-Path $Root 'bench'

function Get-Health {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 "http://127.0.0.1:$ProxyPort/api/method/portfolio_sim.health.status"
        return [pscustomobject]@{ code = [int]$r.StatusCode; body = ($r.Content | ConvertFrom-Json).message }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $body = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
            try { $msg = ($body | ConvertFrom-Json).message } catch { $msg = $body.Substring(0, [Math]::Min(300, $body.Length)) }
            return [pscustomobject]@{ code = [int]$resp.StatusCode; body = $msg }
        }
        return [pscustomobject]@{ code = 0; body = "$($_.Exception.Message)" }
    }
}

switch ($Command) {
    'start' {
        foreach ($s in $order) {
            if ((Get-Service $s).Status -ne 'Running') { Start-Service $s; (Get-Service $s).WaitForStatus('Running', '00:02:00') }
            Write-Host "$s running"
        }
    }
    'stop' {
        [array]::Reverse($order)
        foreach ($s in $order) {
            if ((Get-Service $s -ErrorAction SilentlyContinue).Status -eq 'Running') { Stop-Service $s -Force; (Get-Service $s).WaitForStatus('Stopped', '00:04:00') }
            Write-Host "$s stopped"
        }
    }
    'restart' { & $PSCommandPath stop -Root $Root; & $PSCommandPath start -Root $Root }
    'status' {
        $wmi = Get-CimInstance Win32_Service | Where-Object Name -like 'portfolio-erp-*'
        $rows = foreach ($s in $order) {
            $w = $wmi | Where-Object Name -eq $s
            $child = $null
            if ($w -and $w.ProcessId) {
                $child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($w.ProcessId)" | Where-Object Name -notlike 'conhost*' | Select-Object -First 1
            }
            $p = if ($child) { Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue } elseif ($w.ProcessId) { Get-Process -Id $w.ProcessId -ErrorAction SilentlyContinue }
            [pscustomobject]@{ Service = $s; State = $w.State; Start = $w.StartMode; Pid = $p.Id; Prio = $p.PriorityClass; WS_MB = if ($p) { [int]($p.WorkingSet64 / 1MB) }; Private_MB = if ($p) { [int]($p.PrivateMemorySize64 / 1MB) } }
        }
        $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        $h = Get-Health; Write-Host "health: HTTP $($h.code)"; $h.body | ConvertTo-Json -Depth 5 | Write-Host
    }
    'health' { $h = Get-Health; $h.body | ConvertTo-Json -Depth 5; if ($h.code -ne 200) { exit 1 } }
    'frappe' {
        $py = Join-Path $bench 'env\Scripts\python.exe'
        $argv = @((Join-Path $Root 'adapt\frappe_win.py'), 'frappe')
        if (-not $NoSite) { $argv += @('--site', $Site) }
        $argv += $Rest | Where-Object { $_ -ne '--' }
        $env:PYTHONUTF8 = '1'; $env:PYTHONUNBUFFERED = '1'
        $env:PATH = "$Root\mariadb\bin;$env:PATH"
        $psi = [Diagnostics.ProcessStartInfo]::new($py)
        $psi.Arguments = ($argv | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
        $psi.WorkingDirectory = Join-Path $bench 'sites'; $psi.UseShellExecute = $false
        if ($LogFile) { $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true }
        $p = [Diagnostics.Process]::Start($psi)
        try { $p.PriorityClass = 'BelowNormal' } catch {}
        if ($LogFile) {
            $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync(); $p.WaitForExit()
            [IO.File]::WriteAllText($LogFile, $o.Result + "`n--- stderr ---`n" + $e.Result)
        } else { $p.WaitForExit() }
        exit $p.ExitCode
    }
}
