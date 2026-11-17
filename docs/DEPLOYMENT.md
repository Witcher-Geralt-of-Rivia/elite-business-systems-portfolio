# Deployment

> Status: **not yet deployable.** The deployment method is decided in M2 (see `docs/RISKS.md` R-001..R-006). This file will become the step-by-step runbook.

## Target hostnames (sslip.io, no domain purchase)

```text
https://portfolio.<VPS_IP>.sslip.io
https://crm.<VPS_IP>.sslip.io
https://erp.<VPS_IP>.sslip.io
https://pos.<VPS_IP>.sslip.io
```

`<VPS_IP>` is supplied at deploy time via the `PUBLIC_IP` environment variable; it is not committed.

## Operating constraints

- The host already runs a Caddy reverse proxy for unrelated sites. Portfolio routes are added as separate, imported site blocks; the existing configuration is backed up first and validated before reload.
- Databases bind to loopback only. No database or admin port is exposed publicly.
- Remote access (RDP/SSH) and firewall rules are never altered in ways that could lock out the owner.

## Runbook

### Reverse proxy (done 2026-11-17)

1. Host Caddyfile (`C:\srv\caddy\Caddyfile`) = original global options + `import C:/srv/portfolio/caddy/*.caddy` (shape: `infrastructure/proxy/Caddyfile.host.example`).
2. Site templates live in `infrastructure/proxy/sites/*.caddy.tmpl`. Render and hot-reload:
   ```powershell
   $env:PUBLIC_IP = '<VPS_IP>'
   .\scripts\provisioning\render-caddy-sites.ps1      # validates; restores previous files on failure; graceful reload
   ```
3. Caddy runs as `NT SERVICE\caddy`. Each new portfolio directory it must read needs an explicit grant (the parent `C:\srv` is locked down):
   ```powershell
   icacls C:\srv\portfolio\<dir> /grant "NT SERVICE\caddy:(OI)(CI)(RX)"   # read-only content
   icacls C:\srv\portfolio\logs  /grant "NT SERVICE\caddy:(OI)(CI)(M)"    # logs only
   ```
   Symptom when missing: `caddy reload` → HTTP 400 "mkdir … Cannot create a file when that file already exists"; the running config stays unchanged.

### Runtime layout on the host

```text
C:\srv\portfolio\
  caddy\        rendered site files (imported by host Caddyfile)
  portal\www\   portal static build
  logs\         access/app logs (rotated)
  backups\      per-app DB backups (never committed)
```

Application runbooks: _TBD (M4–M6)._

## Backup & restore

_TBD (M3–M6), per application._

## Recovery

_TBD (M3)._
