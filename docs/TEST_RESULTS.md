# Test Results & Evidence

Only results actually executed are recorded here. Each entry: date · milestone · what was checked · command/tool · result.

## M0 — Repository creation

| Date | Check | Method | Result |
|---|---|---|---|
| 2026-11-17 | Authenticated GitHub identity | `gh auth status`, `gh api user` | `Witcher-Geralt-of-Rivia` (User), scopes `repo, workflow, read:org, gist` |
| 2026-11-17 | Name availability | `gh api repos/<owner>/elite-business-systems-portfolio` | 404 before creation (name free) |
| 2026-11-17 | Repository created | `gh repo create … --public --add-readme` | https://github.com/Witcher-Geralt-of-Rivia/elite-business-systems-portfolio |
| 2026-11-17 | Visibility | `gh api repos/…` → `visibility` / `private` | `public` / `false` |
| 2026-11-17 | Default branch | `gh api repos/…` → `default_branch` | `main` |
| 2026-11-17 | Issues enabled | `gh api repos/…` → `has_issues` | `true` |
| 2026-11-17 | Actions enabled | `gh api repos/…/actions/permissions` | `enabled: true` |
| 2026-11-17 | Initial commit exists | `gh api repos/…/commits` | `bcae897` "Initial commit" |
| 2026-11-17 | Write access | `gh api repos/…` → `permissions` | `admin/push: true` |
| 2026-11-17 | Tracking structure pushed | `gh api repos/…/commits/main` | `16dc51f` with all 15 files listed |
| 2026-11-17 | README publicly readable | unauthenticated `curl` of raw README | HTTP 200 |

## M2 — Windows VPS compatibility (read-only inspection)

| Date | Check | Method | Result |
|---|---|---|---|
| 2026-11-17 | OS edition/build | `Win32_OperatingSystem` | Windows Server 2025 Standard, build 26100 |
| 2026-11-17 | Host is a VM guest | `Win32_ComputerSystem` | Model "Virtual Machine", `HypervisorPresent=True` |
| 2026-11-17 | Virtualization exposed to guest | kernel32 `IsProcessorFeaturePresent(21 VIRT_FIRMWARE_ENABLED, 20 SLAT)` | **False / False** → no nested virtualization |
| 2026-11-17 | WSL / VirtualMachinePlatform | `Get-WindowsOptionalFeature` | both Disabled (WSL2 impossible regardless; WSL1 would need feature + reboot) |
| 2026-11-17 | Docker | `Get-Command docker` | not installed |
| 2026-11-17 | CPU / RAM / disk | CIM + `Get-PSDrive` | 2 cores / 3 logical; 12 GB RAM, ~5.8 GB free; ~18 GB free on C: |
| 2026-11-17 | Native runtimes present | `Get-Command` | Node 24.19, Python 3.13; no PHP, MySQL/MariaDB, Redis |
| 2026-11-17 | sslip.io DNS | `Resolve-DnsName {portfolio,crm,erp,pos}.<VPS_IP>.sslip.io` | all 4 resolve to the VPS public IP |
| 2026-11-17 | Existing reverse proxy | service inspection | Caddy (Windows service) on public IP :80/:443, per-site blocks appended to one Caddyfile, file-system cert storage |
| 2026-11-17 | Public HTTPS via sslip.io on this host (pre-consolidation) | `curl -I https://<existing-site>.<VPS_IP>.sslip.io` | HTTP 200, `ssl_verify_result=0` (publicly trusted cert); HTTP→HTTPS 308 redirect |

## Consolidation (D-008) — 2026-11-17

| Check | Method | Result |
|---|---|---|
| Pre-change backups | config copies, service definitions, scheduled-task export, static site copy; data copies taken after stop; owner's own DB backup task run on demand | OK — DB dump + media archive with SHA-256 files; host-side backup dir restricted to Administrators/SYSTEM |
| New host Caddyfile | `caddy validate` on staged file, then on live file | `Valid configuration` |
| First reload attempt | `caddy reload` | **Rejected** (HTTP 400: Caddy service account could not open the new log dir). Running config unchanged — no outage. Fixed by granting `NT SERVICE\caddy` least-privilege ACLs. |
| Second reload | `caddy reload` | exit 0, service Running |
| Retired services | `Stop-Service`, `Set-Service -StartupType Disabled`, listener check | 3 services Stopped/Disabled; no listeners left on their ports |
| Retired hostnames unreachable | `curl https://<site>.<VPS_IP>.sslip.io` ×4 | TLS handshake refused (no cert served), HTTP only yields Caddy's generic 308 → HTTPS failure. No content reachable. |
| Portfolio over HTTPS (M3 acceptance) | `curl https://portfolio.<VPS_IP>.sslip.io/healthz` | `ok`, HTTP 200, `ssl_verify_result=0` (publicly trusted cert issued on first request) |
| Portfolio HTTP→HTTPS | `curl http://portfolio…/` | 308 → https |
| Resources recovered | process working sets before stop; free RAM/CPU/disk before vs after | Retired sites' process trees held **~100 MB** RAM; net free RAM change was within noise (−336 MB, other processes grew). CPU load (73–97%) and RAM pressure come from interactive tooling on the host (editor ≈3.2 GB across 27 processes, desktop AI/remote-access clients ≈1.2 GB, antivirus). Disk unchanged (no deletion, by design). Free: ~3.9 GB RAM, 17.6 GB disk. |
