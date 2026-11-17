# Risk Register

Severity: **H**igh / **M**edium / **L**ow. Evidence cites the inspection that raised the risk.

| ID | Sev | Risk | Evidence | Mitigation / next step | Status |
|---|---|---|---|---|---|
| R-001 | H | Nested virtualization unavailable → no WSL2, no Hyper-V, no Linux containers on the VPS | `Win32_Processor.VirtualizationFirmwareEnabled=False`, `SecondLevelAddressTranslationExtensions=False`; host is itself a VM. Not yet conclusively confirmed. | M2: confirm with a read-only CPU feature check (e.g. Sysinternals Coreinfo `-v`). If confirmed, evaluate native-Windows runtimes and WSL1. | open |
| R-002 | H | ERPNext/Frappe has no supported native Windows runtime | Frappe docs target Linux/macOS; production via Docker or bench on Linux | Depends on R-001. Options: WSL1 bench (unsupported-ish, slow I/O), or ERP hosted elsewhere (needs owner approval: $0 constraint). | open |
| R-003 | H | Supabase self-hosting is Docker-based (Kong, GoTrue, PostgREST, Realtime, Storage) | Supabase self-hosting docs | Depends on R-001. Options: native-Windows subset (Postgres + PostgREST + GoTrue binaries) or Supabase free tier (external service — needs owner approval). | open |
| R-004 | H | Disk headroom ~18 GB free | Inspection 2026-11-17 | Budget per stack in M2; avoid Docker image sprawl; log rotation; backups to compact formats. | open |
| R-005 | M | RAM: 12 GB total, ~6 GB free with existing workloads; 3 logical CPUs | Inspection 2026-11-17 | ERPNext alone wants ~2–4 GB. Staged activation and throttled simulators likely required. | open |
| R-006 | H | Existing production Caddy and other services share the host | Caddy service bound to 80/443 | Extend existing Caddy config via imported site files; back up config; validate with `caddy validate` before reload; never restart unrelated services. Requires owner approval before first change. | open |
| R-007 | M | Let's Encrypt rate limits on sslip.io (shared registered domain) | sslip.io docs note rate-limit exposure | Stagger issuance; use staging CA while testing; persistent cert storage. | open |
| R-008 | L | Public repo could leak host details or secrets | — | D-004; secret scan before each push; `.gitignore` covers env/dumps/keys. | mitigated |
