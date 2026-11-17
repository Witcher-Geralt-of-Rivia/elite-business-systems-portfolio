# Upstream provenance

This directory starts as an unmodified snapshot of **Atomic CRM** by Marmelab
(https://github.com/marmelab/atomic-crm), MIT License (see `LICENSE.md`),
taken at commit `22f38f0f5918187a9c559e75dcc4cd4a329f9af2` (2026-11-17, CHANGELOG head v1.6.0).

Excluded from the snapshot: upstream git history, documentation site (`doc/`, `docs/`),
Supabase project (`supabase/` — replaced by `apps/crm/backend`), CI, devcontainer,
storybook, shadcn registry, and upstream's agent-harness configuration.

All portfolio changes are made in later, separate commits so `git log -- apps/crm/frontend`
shows exactly what differs from upstream.
