# Upstream provenance

This directory starts as an unmodified snapshot of **Atomic CRM** by Marmelab
(https://github.com/marmelab/atomic-crm), MIT License (see `LICENSE.md`),
taken at commit `22f38f0f5918187a9c559e75dcc4cd4a329f9af2` (2026-11-17, CHANGELOG head v1.6.0).

Excluded from the snapshot: upstream git history, documentation site (`doc/`, `docs/`),
Supabase project (`supabase/` — replaced by `apps/crm/backend`), CI, devcontainer,
storybook, shadcn registry, and upstream's agent-harness configuration.

`CHANGELOG.md` was added after the initial snapshot (same upstream commit) because the in-app
Changelog page imports it at build time.

All portfolio changes are made in later, separate commits so `git log -- apps/crm/frontend`
shows exactly what differs from upstream.

## Portfolio changes (summary; `git log -- apps/crm/frontend` has the details)

**Added** (portfolio-owned): `src/components/atomic-crm/providers/portfolio/*` (data/auth providers,
file upload, live updates, one-time link dialog, password-link button, messages),
`src/components/auth/*` (set-password and forgot-password pages; `layout.tsx` moved from
`components/supabase/`), `e2e-portfolio/*`, `playwright.portfolio.config.ts`,
`vite.portfolio-e2e.config.ts`.

**Removed** (Supabase): `providers/supabase/`, `components/supabase/` (incl. the OAuth consent page),
`scripts/supabase-remote-init.mjs`, packages `@supabase/supabase-js`, `supabase`,
`ra-supabase-core`, `ra-supabase-language-english|french`, the `functions` Vitest project.

**Modified upstream files** (minimal, each for a stated reason):

| File | Change | Reason |
|---|---|---|
| `root/CRM.tsx` | providers from `providers/portfolio`; auth pages from `components/auth`; OAuth route removed; layouts wrapped with `withPortfolioServices` | Supabase removal; live updates + link dialog on every page |
| `providers/types.ts` | re-exports the portfolio `CrmDataProvider` type | Supabase removal |
| `providers/commons/i18nProvider.ts` (+ test) | `ra-supabase` catalogs replaced by `providers/portfolio/messages.ts` | Supabase removal; no "email sent" promises without an email service |
| `login/LoginPage.tsx` | forgot-password label key `crm.auth.forgot_password` | Supabase i18n removal |
| `root/config.ts`, `scripts/renderRuntimeConfig.ts` (+ test) | `supabaseUrl`/key replaced by optional `mcpUrl` | Supabase removal |
| `settings/ProfilePage.tsx`, `settings/SettingsPageMobile.tsx` | MCP section shown only when `mcpUrl` is configured | upstream MCP server was a Supabase edge function; no dead URL |
| `sales/SalesEdit.tsx` | "Password link" button in the toolbar | admins issue invitation/reset links (no email service) |
| `vitest.config.ts`, `package.json` | Supabase functions project, scripts and packages removed | Supabase removal |
