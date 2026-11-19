<#
.SYNOPSIS
  Prepared (not applied): restart-on-failure recovery actions for the database services.

.DESCRIPTION
  The CRM PostgreSQL, POS MariaDB and co-hosted PostgreSQL services start at boot but have no failure actions, so a
  crash leaves them stopped until someone intervenes. This script shows the current and proposed settings; it changes
  nothing unless -Apply is given.

  -Apply changes production service configuration and therefore needs the owner's authorisation. The co-hosted
  application's database is excluded unless -IncludeCoHosted is also given (separate owner authorisation, D-016).

  Proposed: restart after 10 s, then 30 s, then 60 s; failure count reset after one day (`sc.exe failure`). Only the
  service's recovery settings change; the service is not stopped or restarted.
#>
[CmdletBinding()]
param([switch]$Apply, [switch]$IncludeCoHosted)
$ErrorActionPreference = 'Continue'
$targets = @('portfolio-crm-postgres', 'portfolio-pos-mariadb')
if ($IncludeCoHosted) {
    # Identifiers live only on the host (C:\srv\portfolio\config\cohosted.json), not in this public repository.
    $coCfg = Get-Content 'C:\srv\portfolio\config\cohosted.json' -Raw | ConvertFrom-Json
    $targets += @(Get-Service | Where-Object { $n = $_.Name; @($coCfg.database_service_patterns | Where-Object { $n -like $_ }).Count } | ForEach-Object Name)
}
foreach ($n in $targets) {
    $current = (& sc.exe qfailure $n 2>$null | Select-String 'RESTART|RUN|REBOOT -- ' | ForEach-Object { $_.Line.Trim() }) -join '; '
    Write-Host "$n current: $(if ($current) { $current } else { 'no failure actions' })"
    Write-Host "$n proposed: sc.exe failure $n reset= 86400 actions= restart/10000/restart/30000/restart/60000"
    if ($Apply) {
        & sc.exe failure $n reset= 86400 actions= restart/10000/restart/30000/restart/60000 | Out-Host
        Write-Host "$n applied: $((& sc.exe qfailure $n | Select-String 'RESTART' | ForEach-Object { $_.Line.Trim() }) -join '; ')"
    }
}
if (-not $Apply) { Write-Host 'dry run: nothing changed (use -Apply only with owner authorisation)' }
