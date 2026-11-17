# Decision Log

Format: ID · date · decision · alternatives rejected · status.

## D-001 · 2026-11-17 · Single public portfolio repo; upstreams referenced, not vendored
- Upstream code is pinned by revision (submodule or scripted checkout into git-ignored `upstream/`), customizations live in this repo.
- Rejected: copying three full upstream histories in (bloats repo, obscures what is original work, complicates license boundaries).
- Status: accepted.

## D-002 · 2026-11-17 · Repo-local git identity uses GitHub no-reply email
- Commits use `<id>+<login>@users.noreply.github.com` so the owner's personal email never enters public history.
- Status: accepted.

## D-003 · 2026-11-17 · Licensing structure
- Original, separable portfolio components (portal, generic tooling, infra scripts, CRM customizations): MIT (root `LICENSE`).
- ERPNext and NexoPOS extensions (Frappe app, NexoPOS module): GPL-3.0, each with its own `LICENSE` file in its directory, because they link against GPL code.
- Rejected: a single MIT license for everything (would misstate obligations for GPL derivatives).
- Status: accepted; owner may choose a different license for original components.

## D-004 · 2026-11-17 · Host-identifying details stay out of the public repo
- Public IP, port/service inventory, and VPS usernames are not committed. Configuration takes `PUBLIC_IP` from the environment; docs use `<VPS_IP>`.
- Note: the deployed sslip.io hostnames necessarily embed the IP once the portal is live; that is an accepted, deliberate exposure at deployment time, not in source.
- Status: accepted.
