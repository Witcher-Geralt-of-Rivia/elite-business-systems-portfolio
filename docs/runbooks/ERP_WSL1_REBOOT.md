# Runbook: enable WSL1 for the ERPNext proof of concept (requires ONE reboot)

**Status:** awaiting owner approval. Nothing in this runbook has been executed.

## Why a reboot

The host has no nested virtualization (R-001), so WSL2 is impossible. WSL1 needs only the
`Microsoft-Windows-Subsystem-Linux` optional feature, which Windows reports as
`RestartRequired: Possible`; in practice enabling it completes on the next boot. The
`VirtualMachinePlatform` feature is **not** needed and will **not** be enabled.

Read-only state on 2026-11-17: feature `Disabled`, no pending-reboot flags, last boot 2026-11-09.

## What the reboot affects

| Item | During reboot (~2–5 min typical) | After reboot |
|---|---|---|
| Portfolio sites (portal, CRM) | unavailable | start automatically (`caddy`, `portfolio-crm-postgres`, `portfolio-crm-api` are Auto) |
| Owner remote access | RDP/SSH/AnyDesk/RustDesk/Jump drop | `sshd`, AnyDesk, RustDesk, JumpConnect are Auto; RDP (TermService) is a Windows default and listens on 3389 after boot |
| Other owner services | stop | `postgresql-x64-16`, `practica-postgres` are Auto; retired sites stay Disabled (D-008) |
| Interactive sessions | editor windows, this agent session, manually started dev servers (e.g. n8n, Next.js demos) **end** | **not** restarted automatically — they were started by hand |
| Scheduled tasks | — | unchanged |

## Procedure (owner or agent, with approval)

1. **Before** — record state and push the git checkpoint:
   ```powershell
   Get-Service caddy, portfolio-crm-postgres, portfolio-crm-api, sshd | Format-Table Name, Status, StartType
   git -C "C:\Workstation\CRM, ERP, POS\elite-business-systems-portfolio" status --short   # must be clean
   ```
2. **Enable the feature without restarting**, then restart at a chosen time:
   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
   Restart-Computer   # only at the approved time
   ```
3. **After** — verify (target: all checks pass within 10 minutes of boot):
   ```powershell
   (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux).State   # Enabled
   Get-Service caddy, portfolio-crm-postgres, portfolio-crm-api, sshd | Format-Table Name, Status
   curl.exe -s https://portfolio.<VPS_IP>.sslip.io/healthz        # ok
   curl.exe -s https://crm.<VPS_IP>.sslip.io/api/health           # {"status":"ok"}
   wsl --set-default-version 1
   wsl --status
   ```
4. Start a new agent session; it resumes from `state/checkpoint.json`.

## Rollback

- Feature: `Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart`, then reboot at a convenient time. No other system setting is changed by this runbook.
- If a portfolio service fails to start after boot: `Start-Service <name>`; logs under `C:\srv\portfolio\logs`. The services are independent of WSL.
- If remote access does not return: the VPS provider's console (out-of-band) is the recovery path — confirm it is available **before** approving.

## After approval: ERP proof of concept (time-boxed)

Distro: Ubuntu 24.04 (WSL1) with `uv`-managed Python 3.14, Node 24, Frappe bench v16.60.0; MariaDB 11.8
and a Redis-compatible server run **natively on Windows** (WSL1 shares the network stack), avoiding
WSL1's weakest areas (InnoDB AIO, Redis under syscall translation). Go/no-go criteria: `bench new-site`
succeeds, ERPNext v16 installs, a Sales Invoice can be submitted, and steady-state RAM fits the budget.
If any fails, ERP remains repo-complete but undeployed, with the evidence documented.
