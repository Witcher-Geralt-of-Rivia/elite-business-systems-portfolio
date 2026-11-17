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

## Where things are

- Requirements: `docs/MASTER_SPECIFICATION.md` (requirement IDs referenced in commits/tests)
- Milestones: `docs/ROADMAP.md`
- Evidence: `docs/TEST_RESULTS.md`
