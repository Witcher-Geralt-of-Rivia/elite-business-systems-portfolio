# Runbook: enable WSL1 for the ERPNext proof of concept (requires ONE reboot)

**Status:** awaiting owner approval. Nothing in this runbook has been executed.

## Why a reboot

The host has no nested virtualization (R-001), so WSL2 is impossible. WSL1 needs only the
`Microsoft-Windows-Subsystem-Linux` optional feature, which Windows reports as
`RestartRequired: Possible`; in practice enabling it completes on the next boot. The
`VirtualMachinePlatform` feature is **not** needed and will **not** be enabled.

Read-only state on 2026-11-17: feature `Disabled`, no pending-reboot flags, last boot 2026-11-09.

## What the reboot affects

> Updated 2026-11-18 for Release 1.0: the reboot now also affects the public POS, the monitoring task and the
> owner's co-hosted application. The full PoC plan with pass/fail gates is [ERP_WSL1_POC.md](ERP_WSL1_POC.md).

| Item | During reboot (~2–5 min typical) | After reboot |
|---|---|---|
| Portfolio sites (portal, CRM, POS) | unavailable | start automatically: `caddy`, `portfolio-crm-postgres`, `portfolio-crm-api`, `portfolio-pos-mariadb`, `portfolio-pos-php-1/-2` and `portfolio-pos-sim` are Auto. The CRM and POS simulations catch up from their persisted state without duplicates (tested) |
| Monitoring and backups | — | `Portfolio - health monitor` runs on its 15-minute repetition; nightly backups unchanged. Expect monitor events 1001/1000 if a check runs before services are up |
| Owner's co-hosted application | unavailable | its services are Auto (D-016); verify it is reachable |
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
2. **Enable the feature without restarting**, then restart at a chosen time. WSL1 only: never run `wsl --install`
   (it enables VirtualMachinePlatform and WSL2), and do not enable VirtualMachinePlatform or Hyper-V:
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

## After approval: ERP proof of concept

Superseded by the staged plan [ERP_WSL1_POC.md](ERP_WSL1_POC.md). It defines pass and fail criteria per stage,
failure criteria F1–F7 and alternatives A1–A4. ERPNext gets its **own** native MariaDB 11.8 instance, so the POS
database server is not reconfigured.
