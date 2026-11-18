# Security Investigation — suspicious scheduled task (2026-11-17)

**Verdict: CONFIRMED MALICIOUS SOFTWARE was executed on the VPS on 2026-10-07.**
No evidence of *current* malicious activity was found, but the host cannot be considered
trustworthy (see §6). This document is sanitized for a public repository: host name, IP, machine
SID, user-installed software inventory and raw logs are kept only in a restricted local evidence
folder (Administrators/SYSTEM).

Method: read-only analysis. Nothing suspicious was executed, re-enabled, modified, quarantined or
deleted. Defender scans were run in **detect-only** mode (`MpCmdRun -DisableRemediation`).

## 1. Summary of findings

| # | Finding | Evidence | Confidence |
|---|---|---|---|
| F1 | A password-protected archive lure was opened and its "setup" launched | Shell "Recent" shortcuts: `SETUP_PACKAGE_(KEY=4011).zip` (15:33:56) → nested `UNL0CK_SETUP.zip` extracted to a temp folder (15:33:59, note the digit zero) → `SETUP.zip` (15:37:20) | High |
| F2 | A malicious payload was dropped 2 s later | `%APPDATA%\<12-hex-char folder>\app.asar`, 1,490,305 bytes, created 15:37:22. Despite the Electron extension it is a **Python script** whose first line is `import gzip,marshal` followed by `exec(marshal.loads(gzip.decompress(...` — an obfuscated loader that executes hidden bytecode. | High |
| F3 | Code executed (not just downloaded) | (a) A scheduled task was **registered** at 15:42:48 — registration requires running code; (b) the Python `utf_16_le` codec cache was compiled at 15:38:46, 84 s after the drop, consistent with the payload running under the locally installed Python 3.13; (c) a staging folder `%APPDATA%\Google\Runtime` was created at 15:41:14 | High |
| F4 | Persistence was installed | Hidden task with a random decoy name (`Estee Mn Confirmation <n>-<SID>`), **logon trigger** for the built-in Administrator, action `%APPDATA%\Google\Runtime\CLRHost\<16-hex>\complex.exe`, no author/description | High |
| F5 | Persistence is currently inert | Task state **Disabled** (last modified 2026-10-08 20:23, actor unknown), never ran (`0x41303`); the `complex.exe` payload and its folder no longer exist; `%APPDATA%\Google\Runtime` is empty | High |
| F6 | The infected account is the built-in Administrator (RID 500) | Task principal SID ends in `-500`. On Windows Server this account is not filtered by UAC, so the payload ran with **full administrative rights** | High |
| F7 | Defender never detected any of it | Defender operational log (retained since 2025-07) has no detection events; targeted detect-only scans of the payload and staging folder: "found no threats" | High |
| F8 | No other persistence found | Run/RunOnce keys, startup folders, services, WMI subscriptions (only the Windows default `SCM Event Log Filter`), Winlogon, IFEO debuggers, other hidden tasks: nothing unexplained | Medium (fileless/kernel persistence cannot be excluded by this method) |
| F9 | No active malicious process or connection observed | No process runs from user-writable paths; all established outbound connections belong to recognised applications (editor, AI clients, browser, remote-access tools, Windows) | Medium (point-in-time snapshot) |
| F10 | Defender hardening gaps | Tamper Protection **off**; one path exclusion for a third-party browser application's folder (no logged change event); last full scan 30 days ago | High |
| F11 | Unrelated unsigned tool, origin unverified | A 45 MB unsigned PyInstaller executable in Downloads (downloaded 2026-10-08, last run 2026-11-13). Its name and the account's GitHub activity one minute after it ran are consistent with a legitimate repository tool; Defender: no threats. **Owner must confirm its origin.** | Low suspicion |

Pending: a broad detect-only Defender scan of the user profile, ProgramData and the workspace was
started 2026-11-17 and is still running (slow on this loaded 3-CPU host); its result will be appended
here. A clean result would not change the verdict, because Defender already missed this payload.

Event-log limits: the Security log only reaches back to 2026-11-03 and the Task Scheduler operational
log is disabled, so the task-creation events themselves are no longer available.

## 2. Indicators of compromise

| Type | Value |
|---|---|
| SHA-256 (`app.asar`, Python loader) | `9132737BA8EE70E318546BA8B034AB595C0CCECC66AE70E47DDD2F08A2D240F7` |
| File pattern | `%APPDATA%\<12 hex>\app.asar` containing Python source beginning `import gzip,marshal` |
| Path pattern | `%APPDATA%\Google\Runtime\CLRHost\<16 hex>\complex.exe` |
| Scheduled task | hidden, logon-triggered, name pattern `<word> <word> Confirmation <digits>-<user SID>` |
| Lure | archive names `SETUP_PACKAGE_(KEY=####).zip`, `UNL0CK_SETUP.zip`, `SETUP.zip` |

## 3. Classification

This matches a commodity **information-stealer / loader** campaign delivered through fake
"cracked software" or "setup package" archives: password-protected archive (antivirus evasion),
script payload disguised as an Electron file, decoy-named hidden logon task, payload under a
fake `Google` folder. The typical capability of this class is theft of browser-saved passwords,
session cookies and tokens, cryptocurrency wallets, messaging-app tokens and remote-access/VPN
configuration, often followed by a second-stage download (`complex.exe` here). The second stage's
behaviour cannot be determined because the file is gone.

## 4. Exposure assessment

| Asset | Exposure | Basis |
|---|---|---|
| Browser-saved passwords and session cookies (profile existed since 2026-10-05) | **Assume stolen** | Primary target of this malware class; data existed at infection time |
| Any account logged in through the browser on 2026-10-07 (email, GitHub, cloud/VPS panel, banking, AI tools) | **Assume session hijack possible** | Cookie theft bypasses passwords and often 2FA |
| GitHub CLI token on this host | **Treat as exposed** | Creation time could not be established |
| Remote-access tools, VPN client configuration | **Treat as exposed** | Common stealer targets |
| Portfolio secrets created 2026-11-17 (DB passwords, CRM admin password) | Low | Created after infection; exposed only if attacker access persists |
| Public repository contents | None | Contains no secrets (scanned before every push) |

GitHub account activity since 2026-10-07 (public events and repository list) showed nothing
inconsistent with the owner's own work. This does not rule out silent token use.

## 5. Recommended remediation (owner)

**From a different, trusted device** (not this VPS):

1. Change passwords for every account saved in this host's browser, starting with: primary email, GitHub, VPS provider panel, banking/payment, cloud and AI-service accounts. Then **sign out all sessions** for each (GitHub → Settings → Sessions; Google → Security → sign out of all devices).
2. GitHub: review and revoke unknown **SSH keys, personal access tokens, OAuth app authorizations (including "GitHub CLI"), deploy keys, Actions secrets**; check the account security log for 2026-10-07 onward; confirm 2FA recovery codes are regenerated.
3. VPS provider: change the panel password, rotate API keys, and **confirm out-of-band console access**.
4. Change the Windows Administrator password and the passwords of every installed third-party remote-access tool; review their access lists/trusted devices.

**Host — choose one:**

- **(Recommended) Rebuild:** reinstall the VPS from a clean image and redeploy from GitHub. The payload ran with full admin rights and the second stage is unknown, so in-place cleaning cannot prove the host is clean. The portfolio is designed to redeploy from the repository (scripts + checkpoint), so this costs hours, not weeks.
- **Remediate in place (accepts residual risk):** after evidence is archived, delete the task and the payload/staging folders; enable Defender Tamper Protection; review the path exclusion; enable Task Scheduler operational logging and process-creation auditing; run a Defender **offline** scan (needs a reboot) plus a second-opinion scanner; rotate the portfolio's DB and admin passwords afterwards.

## 6. Impact on the project

- Public deployment of new components and further secret creation on this host are **paused** pending the owner's choice in §5.
- Repository work is unaffected; GitHub remains the source of truth. After credential rotation the agent needs a fresh `gh` login.
- The currently deployed CRM holds no real data (synthetic/empty) and was left running.

## 7. Evidence preserved locally (not in this repository)

Restricted folder (Administrators/SYSTEM only) containing: exported task XML, directory listings,
filesystem timeline (2026-10-07/08), recent-shortcut targets, persistence sweep, Defender status and
event extracts, detect-only scan outputs, connection snapshot, hashes. The payload itself was left in
place, unmodified, for the owner's decision.
