# Progress Log

Newest first. Every entry states what was **verified**, not just what was written.

## 2026-11-17 — Host consolidation done; portfolio HTTPS live (M3 partial)

- Owner decisions D-008 (retire four unrelated sites) and D-009 (CRM without Supabase) recorded; D-007 superseded.
- Four sites retired reversibly: Caddy routes removed via validated graceful reload, three services stopped and Disabled, data untouched, host-side backups + restore script. Verified unreachable over HTTPS.
- `https://portfolio.<VPS_IP>.sslip.io/healthz` → 200 with a publicly trusted certificate (M3 acceptance criterion met; logging/backup/health scripts still pending).
- Resource finding: the retired sites used only ~100 MB; the host's pressure comes from interactive tooling (R-013). Working budget ≈3.9 GB RAM, 17.6 GB disk.

## 2026-11-17 — M1 complete, M2 inspection complete → awaiting owner decisions

- **M1:** audited all four upstreams from source + GitHub API ([UPSTREAM_AUDIT.md](UPSTREAM_AUDIT.md)). Licenses verified (one upstream inconsistency: NexoPOS `composer.json` says MIT, LICENSE says GPL-3.0 → GPL-3.0 applied). Pins chosen (D-005). Simulator integration points identified with file/line references (D-006).
- **M2:** nested virtualization **confirmed unavailable** (kernel API). sslip.io DNS verified for all four hostnames. Public HTTPS via sslip.io proven on this host by an existing Caddy site (trusted cert, 308 redirect). Native runtime strategy proposed (D-007).
- **Stopped before any VPS modification.** Next steps install software on a shared production host and need a reboot (WSL feature) and a change to the shared Caddyfile; both require owner approval. See checkpoint `owner_decisions_needed`.

## 2026-11-17 — M0: repository created

- Created public repo `Witcher-Geralt-of-Rivia/elite-business-systems-portfolio`; verified visibility, default branch, Issues, Actions, initial commit, write access (see TEST_RESULTS.md §M0).
- Added tracking structure: README, CLAUDE.md, LICENSE (MIT, original work only), `.gitignore`, docs/*, `state/checkpoint.json`.
- Read-only host inspection performed early because the agent turned out to be running on the VPS itself. Findings recorded (sanitized) in ARCHITECTURE.md §3 and RISKS.md R-001..R-006. Most significant: virtualization extensions appear unavailable to the guest OS, which would rule out WSL2/Docker. Not yet conclusively confirmed.
- **Not done yet:** no upstream code cloned; no VPS changes made.
