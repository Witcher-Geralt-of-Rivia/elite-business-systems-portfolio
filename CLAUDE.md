# CLAUDE.md — agent operating notes

This repository is the durable state of a multi-session build. Do not rely on conversation memory.

## Resume protocol (every session)

1. `git pull` and `git status` — note uncommitted work.
2. Read `state/checkpoint.json` (machine state) and `docs/PROGRESS.md` (human log).
3. Read the latest entries in `docs/DECISIONS.md` and `docs/RISKS.md`.
4. Resume at `next_action` of the earliest unfinished milestone. Do not restart completed milestones.

## Hard rules

- **Never commit secrets**: no tokens, passwords, `.env` (only `.env.example`), keys, backups, DB dumps. Run `scripts/verification/check-secrets.ps1` (once it exists) or at minimum `git diff --cached` review before every push.
- **Do not commit host-identifying details** to this public repo: public IP address, the host's port/service inventory, usernames on the VPS. Use placeholders (`<VPS_IP>`) and the `PUBLIC_IP` env var.
- **The VPS runs other, unrelated production workloads** (an existing Caddy reverse proxy on 80/443, PostgreSQL services, Node apps, RDP/SSH). Never stop, reconfigure, or replace them without explicit owner approval. Back up any config before touching it, and keep a rollback path. Never change firewall/RDP/SSH/network-adapter settings in a way that could lock the owner out.
- No paid services, domains, or plugins. Public hostnames use sslip.io only.
- Never mark something verified without recorded evidence in `docs/TEST_RESULTS.md`.
- Use upstream extension mechanisms (Frappe custom apps, NexoPOS modules, Atomic CRM's customization props) before patching upstream core.
- Synthetic data goes through each application's own services/APIs (ERPNext document lifecycle, NexoPOS order services, Supabase/PostgREST with RLS) — never raw inserts that bypass business validation.

## Git

- Repo-local identity uses the GitHub no-reply address; keep it that way.
- Conventional commits: `feat(crm):`, `infra:`, `docs:`, `test(erp):` …
- Commit messages end with the `Co-Authored-By` trailer for the agent.
- Feature branches + PRs for substantial changes once `main` holds working code.

## Host gotchas (learned the hard way)

- **Windows PowerShell 5.1 + native tools:** with `$ErrorActionPreference='Stop'`, any stderr line from a native exe (Caddy's info logs, psql NOTICEs, Vite warnings) becomes a terminating error. Wrap native calls in a helper that sets `'Continue'` locally and judges by `$LASTEXITCODE` (see `Invoke-Native` in `scripts/provisioning/deploy-crm.ps1`).
- **Caddy runs as `NT SERVICE\caddy`** and `C:\srv` is locked down: grant RX on any new web root and M on log dirs, or `caddy reload` fails with "mkdir … file exists" (running config stays intact).
- **`initdb`/`postgres` drop admin rights** (restricted token): data dirs need explicit grants for the current user and the service account.
- **SYSTEM PowerShell cold start ≈ 60 s** on this host (antivirus + CPU load). Scheduled tasks are not hung just because they take a minute.
- **Secure cookies:** the CRM session cookie is `Secure`; test over `https://crm.<ip>.sslip.io`, not `http://127.0.0.1:8810`.
- **Atomic CRM uses hash routing with relative assets** (`base: "./"`): browser tests must navigate to `/#/...`.
- **Secrets layout:** `C:\srv\portfolio\secrets` is Administrators/SYSTEM only. Service accounts get read on their own env file only; superuser URLs live in separate `*-migrate.env` files.

## Where things are

- Requirements: `docs/MASTER_SPECIFICATION.md` (requirement IDs referenced in commits/tests)
- Milestones: `docs/ROADMAP.md`
- Evidence: `docs/TEST_RESULTS.md`
