# CRM: Supabase removal and migration inventory

Status: analysis for M4 (CRM implementation). Basis: decision D-009 (no Supabase, cloud or self-hosted). Upstream: Atomic CRM @ `22f38f0f`, read-only at `upstream/atomic-crm/`. **All `file:line` citations below are relative to that directory.** "[inferred]" marks statements not verified against source (e.g. `ra-supabase-core` internals; `node_modules` is not installed).

Target: Atomic CRM SPA (unchanged look) → same-origin `/api/*` → Fastify (Node 24, Windows service) → PostgreSQL 16, db `crm`, role `crm_app` (no superuser, no DDL, no `BYPASSRLS`). The browser never reaches Postgres. Extensions available: contrib only (`citext`, `unaccent`, `pgcrypto`, `pg_trgm`). **No `http`, no `pg_net`.**

---

## 1. SDK dependency inventory

| Package (package.json) | Kind | Importers | Replacement |
|---|---|---|---|
| `@supabase/supabase-js` ^2.90.1 | dep | `src/.../providers/supabase/supabase.ts:1-2` (only `createClient` call, :7-12); `e2e/fixtures.ts:2`; `e2e/signup.spec.ts:1` | Remove. Plain `fetch` wrapper in new provider; `pg` in e2e fixtures |
| `ra-supabase-core` ^3.5.2 | dep | `providers/supabase/dataProvider.ts:1` (`supabaseDataProvider`), `providers/supabase/authProvider.ts:2` (`supabaseAuthProvider`), `components/supabase/forgot-password-page.tsx:2` (`useResetPassword`), `components/supabase/set-password-page.tsx:3` (`useSetPassword`, `useSupabaseAccessToken`) | Remove. Own `httpDataProvider`, `httpAuthProvider`, two small hooks |
| `ra-supabase-language-english` / `-french` ^3.5.0 | dep | `providers/commons/i18nProvider.ts:5-6` | Remove; copy the 13 `ra-supabase.*` keys used (auth.forgot_password, auth.missing_tokens, auth.password_reset, oauth.* x6, reset_password.* x2, set_password.new_password, validation.password_mismatch) into `crm.*` messages EN/FR |
| `supabase` (CLI) ^2.122.0 | devDep | `makefile:29-81`, `package.json` script `supabase:remote:init` | Remove; replaced by SQL migration runner (node script) + Windows service scripts |
| `pgsql-ast-parser` ^12.0.2 | devDep | MCP `validateSql.ts` only [inferred from purpose] | Remove with MCP |

Other Supabase-coupled files (no direct package import): `root/CRM.tsx:14-16,29-32` (route + provider wiring), `providers/types.ts:1` (type re-export of `CrmDataProvider`), `root/config.ts:43-44`, `settings/ProfilePage.tsx:271` and `settings/SettingsPageMobile.tsx:577` (render `${supabaseUrl}/functions/v1/mcp`), `login/LoginPage.tsx:145` (ra-supabase i18n key), `public/auth-callback.html` (Supabase OAuth/SSO callback), `deals/dealUtils.ts:55` and `src/lib/toSlug.ts:6` (comments only).

## 2. DataProvider inventory (`providers/supabase/dataProvider.ts`, 520 lines)

Base: `supabaseDataProvider` (ra-data-postgrest under the hood [inferred]) with `sortOrder: "asc,desc.nullslast"` (:28-34), wrapped by `withLifecycleCallbacks` (:425-428). `getDataProvider` hard-fails without `window._atomicCrmConfig`, `supabaseUrl`, `supabasePublishableKey` (:409-424).

### 2.1 Methods

| Method | Lines | Upstream behaviour | UI call sites | Replacement endpoint / server behaviour |
|---|---|---|---|---|
| `getList` | 57-83 | `companies`→view `companies_summary`, `contacts`→`contacts_summary`; `activity_log` renames `contact_note`/`deal_note`→camelCase; else table | all lists | `GET /api/{res}?filter=&sort=&order=&page=&perPage=` → `{data,total}`. Server maps companies/contacts to summary SQL; activity_log returns camelCase directly |
| `getOne` | 84-93 | same view mapping for companies/contacts | show/edit | `GET /api/{res}/{id}` |
| `getMany` | base | `id=in.(…)`; **not** mapped: `contacts` hits the table, `contacts_summary` used as its own resource (`DealInputs.tsx:56`, `TaskFormContent.tsx:30`, `CompanyShow.tsx:152`, `DealShow.tsx:158`) | references | `GET /api/{res}?ids=1,2,3`; expose `contacts_summary` + `companies_summary` as read-only resource aliases |
| `getManyReference` | base | target filter (`company_id`, `contact_id`, `deal_id`) | `ReferenceManyField` (CompanyShow, ContactAside, CompanyCard), `ContactMergeButton.tsx:94,104` | `GET /api/{res}?filter={target:id,…}` |
| `create` | base | insert; triggers fill `sales_id`, logo, avatar | forms, imports | `POST /api/{res}`; service sets `sales_id` from session, audit, NOTIFY |
| `update` | base | PATCH by id | forms, kanban, BulkTagButton (`useUpdate` per row, `BulkTagButton.tsx:32`) | `PUT /api/{res}/{id}` (partial accepted) |
| `updateMany` | base | `id=in.(…)` | none found in app code [grep] | `PATCH /api/{res}?ids=` (keep for react-admin completeness) |
| `delete` | base | delete; note triggers call attachment cleanup | delete buttons | `DELETE /api/{res}/{id}`; service deletes + schedules file GC |
| `deleteMany` | base | | `BulkDeleteButton` (`ContactList.tsx:12`), SalesList bulk [inferred] | `DELETE /api/{res}?ids=` in one transaction |
| `signUp` | 95-120 | `auth.signUp` with metadata; sets `_is_initialized_cache` | `SignupPage.tsx:35` | `POST /api/auth/bootstrap` — allowed **only while `app_users` is empty**; creates admin user + sales row (replaces `handle_new_user`) |
| `salesCreate` | 121-145 | edge fn `users` POST | `SalesCreate.tsx:28`, `useImportFromJson.ts:160` | `POST /api/users` (admin): create user (no password), sales row, invite token, log mail; 409 `email_taken` |
| `salesUpdate` | 146-195 | edge fn `users` PATCH | `SalesEdit.tsx:48`, `ProfilePage.tsx:63,151`, `SettingsPageMobile.tsx:179,210` | `PATCH /api/users/{salesId}`: self or admin; role/disabled admin-only; secondary-email validation; disabling revokes sessions |
| `updatePassword` | 196-211 | edge fn `update_password` → sends **reset email** (not an in-app change) | `ProfilePage.tsx:125`, `SettingsPageMobile.tsx:70` | `POST /api/auth/password-reset/self` → reset token mailed to outbox. Add optional `POST /api/auth/change-password` (current+new) |
| `unarchiveDeal` | 212-236 | reads ≤1000 deals of stage, N parallel updates reindexing | `DealShow.tsx:259` | `POST /api/deals/{id}/unarchive` — one transaction, server-side reindex |
| `isInitialized` | 237-239 | `init_state` view, localStorage cache | `StartPage.tsx:19`, `SignupPage.tsx:28` | `GET /api/auth/init-state` → `{initialized}` (public) |
| `globalSearch` | 240-255 | RPC `global_search`; throws `HttpError(status)` so 401 logs out | `GlobalSearchButton.tsx:174` | `GET /api/search?q=&resources=&max=`; port SQL function as-is; preserve HttpError status |
| `mergeContacts` | 256-271 | edge fn `merge_contacts` | `ContactMergeButton.tsx:74` | `POST /api/contacts/{loserId}/merge {winnerId}` (manager+) |
| `getConfiguration` | 272-277 | `getOne('configuration',1)` | `CRM.tsx:179,196`, `useConfigurationLoader.ts:17` | `GET /api/configuration` (all authenticated) |
| `updateConfiguration` | 278-287 | update id=1 | **no UI caller**; `SettingsPage.tsx:139-147` uses `EditBase resource="configuration"` → standard `update` | `PUT /api/configuration` (admin); also route `update('configuration',1)` to it |

### 2.2 Lifecycle callbacks (:304-407) and helpers

| Resource | Hook | Behaviour | Replacement |
|---|---|---|---|
| configuration | beforeUpdate :305-315 | upload `lightModeLogo`/`darkModeLogo` files, store URL string (`processConfigLogo` :295-302) | client uploads via `POST /api/files` then saves `/api/files/{id}` URL |
| contact_notes, deal_notes | beforeSave :316-337 | upload every attachment (`uploadToBucket`) | same client hook, new upload function |
| sales | beforeGetList :338-342; beforeSave :343-348 | `q`→ilike first/last name; upload avatar | `q` server-side; avatar upload via files API |
| contacts | beforeGetList :350-363 | `q`→`@or` ilike on first_name,last_name,company_name,title,`email_fts`,`phone_fts`,background | server-side `q` on contacts summary |
| companies | beforeGetList :364-375; beforeCreate :376-386; beforeUpdate :387-389 | `q` on name,phone_number,website,zipcode,city,state_abbr; logo upload; client `created_at` | server-side `q`; server sets `created_at` |
| contacts_summary | beforeGetList :391-396 | `q` on first/last name | server-side |
| deals | beforeGetList :397-406 | `q` on name,description **plus** `categories@ov` from config label match (`searchDealCategories.ts:13-40`, :35) | server-side (service reads configuration) |
| — | `applyFullTextSearch` :431-459 | builds `@or` of `col@ilike` | **moved to server**; provider passes `q` through |
| — | `uploadToBucket` :461-520 | skip if non-blob URL whose `path` has a signed URL; else re-fetch blob, upload as `${Math.random()}${ext}` to bucket, set `fi.src` = **public URL**, `fi.path`, `fi.type` | `uploadFile()` → `POST /api/files` (multipart) → `{id, src:"/api/files/{id}", path:id, type, title}`; skip when `src` already starts with `/api/files/` |

### 2.3 Filter grammar the UI sends (exhaustive grep of `src/`, excl. tests/fakerest)

| Operator key | Semantics | Sites |
|---|---|---|
| `field` (plain) | `=`; array → `IN` | `stage`, `contact_id`, `deal_id`, `company_id`, `sales_id`, `status`, `first_name`, `last_name`, `email` (e.g. `DealsPipeline.tsx:27`, `HotContacts.tsx:30`, `LatestNotes.tsx:18,27`, `TasksListByDueDate.tsx:41`, `useImportFromJson.ts:151`, `ActivityLog.tsx:22`) |
| `@neq` | `<>` | `disabled@neq` (`CompanyInputs.tsx:167`, `ContactInputs.tsx:221`, `AccountManagerInput.tsx:31,60`), `id@neq` (`ContactMergeButton.tsx:85,206`, `AccountManagerInput.tsx:60`), `stage@neq` (`DealsPipeline.tsx:27`) |
| `@gte` / `@lte` | range | `last_seen@gte/@lte` (`ContactListFilter.tsx:47-84,188-221`), `created_at@gte` (`DealsChart.tsx:40`) |
| `@gt` | `>` | `nb_tasks@gt` (`ContactListFilter.tsx:142,261`) — column of `contacts_summary` |
| `@is` / `@not.is` | `IS NULL` / `IS NOT NULL` (value always null) | `archived_at@is` (`DealList.tsx:84`), `archived_at@not.is` (`DealArchivedList.tsx:26`) |
| `@in` | `"(a,b)"` string | `name@in` (`fetchRecordsWithCache.ts:24`); `sales_id@in`, `contact_id@in`, `deal_id@in` only in `commons/activity.ts` (FakeRest path) |
| `@cs` | array contains, `"{1}"` | `tags@cs` (`ContactListFilter.tsx:129,254`), `contact_ids@cs` (`ContactMergeButton.tsx:117`, `commons/mergeContacts.ts:75`) |
| `@ov` | array overlap, `"{a,b}"` | `categories@ov` (`DealList.tsx:51,55`, `searchDealCategories.ts:35`) |
| `q` | resource-specific search | Company/Deal/Contact/Sales lists (`CompanyListFilter.tsx:23`, `DealList.tsx:43`, `ResponsiveFilters.tsx:54`) |
| `@or`, `@ilike` | only generated by the provider (§2.2) | disappear once `q` is server-side |

Server parser: whitelist per resource (column → type → allowed ops), parse PostgREST literal forms `(a,b)` / `{a,b}` into bound parameters, reject anything else with 400. Sort: whitelisted field, `ASC` / `DESC NULLS LAST` (mirrors `asc,desc.nullslast`) [inferred PostgREST default for asc = nulls last]. The FakeRest adapter `providers/fakerest/internal/transformFilter.ts:12-55` already enumerates the same operator set (`eq neq lt lte gt gte is not.is in cs ov or`) — reuse its tests as contract cases. `fts` operator: **not used** anywhere by the UI.

## 3. AuthProvider inventory

`providers/supabase/authProvider.ts` (178 lines) + `components/supabase/*` + `login/*`.

| Item | Location | Upstream | Replacement |
|---|---|---|---|
| login (password) | base `supabaseAuthProvider` :7-22, :105 | `signInWithPassword` [inferred] | `POST /api/auth/login {email,password}` → sets `crm_sid` cookie (httpOnly, Secure, SameSite=Lax, Path=/), returns identity + CSRF token; rate-limit + lockout; disabled users rejected |
| login (SSO) | :96-104, `SSOAuthButton.tsx:26-28`, `LoginPage.tsx:133-138` (only if `googleWorkplaceDomain`) | `signInWithSSO({domain})` (SAML) | out of scope; button hidden by not setting `googleWorkplaceDomain` |
| handleCallback | base [inferred]; wrapped `CRM.tsx:188-202`; `public/auth-callback.html` | OAuth/SSO redirect handler | drop (no external IdP) |
| logout | :107-116 | `signOut({scope:"local"})`, clears localStorage cache | `POST /api/auth/logout` (deletes session row, clears cookie); keep `clearCache()` |
| checkAuth | :117-151 | bypass on `/set-password`, `/forgot-password`, `/sign-up`; uninitialized → redirect `/sign-up`; else session check | same bypass list; `GET /api/auth/session` (401 → login) |
| checkError | base [inferred] | 401/403 → logout | 401 → logout; 403 → stay, notify |
| getIdentity | :9-21, `getSale` :55-83 | `sales` row by `user_id = session.user.id`, cached in localStorage `RaStore.auth.current_sale` | `GET /api/auth/me` → `{id: sales.id, fullName, avatar, role}`; keep cache but invalidate on 401 |
| canAccess | :152-163, `commons/canAccess.ts:13-34` | role = `administrator ? admin : user`; non-admin denied `sales`, `configuration` | 4 roles from `/api/auth/me`; extend `canAccess` matrix (§3.1). **UI-only; server re-checks everything** |
| getIsInitialized | :36-53 | `init_state` view | `GET /api/auth/init-state` |
| OAuth consent (MCP OAuth server) | :164-176, `components/supabase/oauth-consent-page.tsx:28-118`, route `CRM.tsx:256,331` | `auth.oauth.get/approve/denyAuthorization` | drop with MCP; remove route |
| Forgot password | `forgot-password-page.tsx:19-31`, route `CRM.tsx:252-254` | `useResetPassword` → GoTrue recovery mail | `POST /api/auth/password-reset {email}` → always 202; token (32 B random, SHA-256 stored, 1 h TTL, single use) written to mail outbox/log |
| Set password | `set-password-page.tsx:16-53`, route `CRM.tsx:251` | needs `access_token`+`refresh_token` from URL hash | `/set-password?token=…` → `POST /api/auth/password-reset/confirm {token,password}`; same page serves invite acceptance; all sessions of that user revoked |
| Sign-up (first user) | `SignupPage.tsx:21-60`, `StartPage.tsx:10-28`, `ConfirmationRequired.tsx` (path `/sign-up/confirm`) | `auth.signUp` + trigger `handle_new_user` (first user = admin, then blocked unless invited/SSO) | `POST /api/auth/bootstrap` (only when no users); or seed admin via CLI script and keep the page unreachable. No email confirmation → drop `ConfirmationRequired` branch |
| Invite flow | edge fn `users` :129-261 + `user_invitations` | create GoTrue user, `inviteUserByEmail` | `POST /api/users` → `auth_tokens(purpose='invite', TTL 72 h)` + outbox mail → `/set-password?token=` |
| Identity ↔ sales | `sales.user_id uuid → auth.users(id)` (`01_tables.sql:100,107,172-173`) | 1:1 | `sales.user_id → app_users(id)` (uuid kept); role column on `app_users` |

### 3.1 RBAC matrix (server-enforced; proposal, not upstream parity)

Upstream has **no record-level rules**: every authenticated user can CRUD every CRM row (`05_policies.sql:20-62` are all `using (true)`); only `configuration` writes (admin, :65-67) and `sales` writes (edge fn only) are restricted.

| Action | admin | manager | sales_rep | showcase (read-only) |
|---|---|---|---|---|
| Read CRM data | all | all | all (team CRM, parity) | all (seeded data) |
| Create companies/contacts/deals/tasks/notes/tags | ✓ | ✓ | ✓ (owner = self) | ✗ 403 |
| Update/delete records | all | all | own (`sales_id = me`) + tasks/notes they authored; kanban reorder via dedicated endpoint for any deal | ✗ |
| Merge contacts, bulk delete, CSV import | ✓ | ✓ | import ✓, merge/bulk-delete ✗ [proposal] | ✗ |
| Users/invitations, configuration | ✓ | read | ✗ | ✗ |

Implementation: Fastify `preHandler` resolves session → `{userId, salesId, role}`; services take this `actor` explicitly; showcase role blocked globally for non-GET (except `/api/auth/logout`). Optional RLS: `SET LOCAL app.sales_id/app.role` per transaction + policies on `current_setting('app.role', true)` (defense-in-depth, M8).

## 4. Database objects (`supabase/schemas/*.sql`, 1,345 lines; 34 migrations)

Plan: one consolidated baseline migration `crm/001_baseline.sql` derived from `schemas/` (not replaying 34 historical migrations), owned by a migration role; `crm_app` gets DML on app tables only.

### 4.1 Tables (11)

| Table | Lines (01_tables) | Notes / FKs | Decision |
|---|---|---|---|
| companies | 13-33 | `website extensions.citext`; FK `sales_id→sales` :145-146 | keep; `citext` from `public` schema (drop `extensions.` prefix) |
| contacts | 35-53 | `tags bigint[]`, `email_jsonb`, `phone_jsonb`; FK company (cascade) :148-149, sales :151-152 | keep |
| contact_notes | 55-63 | `attachments jsonb[]`; legacy seq `"contactNotes_id_seq"`, PK :179-180; FKs :154-158 | keep; attachments jsonb elements reference `files.id` |
| deals | 65-82 | `contact_ids bigint[]` (no FK), `categories text[]`, `index smallint`, date check :81 | keep |
| deal_notes | 84-92 | FKs :166-170 | keep |
| sales | 94-105 | `email citext`, `user_id uuid` **FK → auth.users** :172-173, uq :107, `secondary_emails` check | adapt: FK → `app_users(id)` |
| tags | 109-113 | — | keep |
| tasks | 115-124 | FK contact (cascade) :175-176; `sales_id` has no FK | keep |
| configuration | 126-130 | singleton id=1 | keep |
| favicons_excluded_domains | 132-135 | seeded (`seed.sql`, 103 lines) | keep only if favicon lookup is kept (§4.3); else drop |
| user_invitations | 137-139 | `user_id uuid` only; RLS on, no policy | drop → `auth_tokens(purpose='invite')` |
| *new* | — | `app_users`, `sessions`, `auth_tokens`, `files`, `audit_log`, `mail_outbox`, `schema_migrations` | add |

Also: schema `private` (:11) is created but unused in current schemas → drop. Extension `http` (:7) → **unavailable, drop**. `citext` (:8) keep.

### 4.2 Views (4)

| View | Lines (03_views) | Decision |
|---|---|---|
| activity_log | 6-72 (`security_invoker`) union of 5 sources | keep; emit camelCase `contactNote`/`dealNote` in SQL to remove client rename (dataProvider.ts:70-77) |
| companies_summary | 74-100 (`nb_deals`, `nb_contacts`) | keep |
| contacts_summary | 102-128 (`email_fts`, `phone_fts`, `company_name`, `nb_tasks` open only) | keep |
| init_state | 130-134 (`security_invoker = off`) | drop → `SELECT EXISTS(SELECT 1 FROM app_users)` in auth service |

### 4.3 Functions (20) and triggers (17)

| Function (02_functions unless noted) | Lines | Supabase dependency | Decision |
|---|---|---|---|
| cleanup_note_attachments | 6-54 | `request.headers`, `net.http_post` (**pg_net**) | drop → NoteService computes removed attachment ids → `files.deleted_at` + GC job |
| get_note_attachments_function_url | 124-170 | `request.jwt.claim.iss`, Kong/docker URLs | drop |
| get_avatar_for_email | 56-85 | `extensions.digest`, `extensions.http_get` (**http**) | move to ContactService (async enrichment job, Node `fetch`, 5 s timeout, feature flag default **off** for showcase — leaks email hashes to Gravatar) |
| get_domain_favicon | 87-122 | `extensions.http_get`, `http_set_curlopt` | move to CompanyService (same job/flag); client fallback `commons/getFaviconUrl.ts` already exists |
| get_user_id_by_email | 172-179 | **auth.users**, SECURITY DEFINER | drop (UserService query on `app_users`) |
| handle_company_saved (trg) | 181-200 | via favicon | move to CompanyService |
| handle_contact_saved (trg) | 212-248 | via avatar | move to ContactService |
| handle_contact_note_created_or_updated (trg) | 202-210 | none | keep as trigger (pure SQL). Note: `last_seen < new.date` never fires when `last_seen` is NULL; UI also writes `last_seen` (`NoteCreate.tsx:91-97`) |
| handle_new_user (trg on auth.users) | 250-275 | **auth.users**, `raw_user_meta_data`, `is_sso_user` | drop → AuthService.bootstrap / UserService.create |
| handle_update_user (trg on auth.users) | 287-301 | **auth.users** | drop → UserService.update writes `sales` directly |
| handle_tag_deleted (trg) | 277-285 | none | keep |
| is_admin | 303-312 | **auth.uid()** | drop (service RBAC); RLS variant uses `current_setting('app.role')` |
| merge_contacts | 314-464 | none, but **no caller** (UI uses edge fn; SQL fn re-created by `migrations/20260309112831_fix_security_warnings.sql:184-186`) | adapt: use as the single transactional implementation behind `POST /api/contacts/:id/merge`; reconcile semantics with edge fn (avatar/first_seen rules differ: SQL :442,453 vs TS `merge_contacts/index.ts:52-73`) |
| lowercase_email_jsonb (trg) | 466-481 | none | keep |
| set_sales_id_default (trg x6) | 483-493 | **auth.uid()** | drop triggers; services set `sales_id = actor.salesId` when absent (or `current_setting('app.sales_id')`) |
| search_unaccent (08_search) | 12-15 | `extensions.unaccent` | adapt: `public.unaccent` (contrib) |
| search_document / search_query / search_attachment_titles | 20-28 / 32-39 / 41-44 | none | keep |
| global_search | 116-193 | grants to `authenticated` :195-196 | keep as-is; `GRANT EXECUTE … TO crm_app` |

Triggers (04_triggers): `set_*_sales_id_trigger` ×6 (:7-29) drop; `company_saved` (:32-34) drop; `10_lowercase_contact_emails` (:37-39) keep; `20_contact_saved` (:42-44) drop; `on_public_contact_notes_created_or_updated` (:47-49) keep; 4× `*_delete_note_attachments` (:52-71) drop; `on_tag_deleted` (:74-76) keep; `on_auth_user_created/updated` on `auth.users` (:79-85) drop. **Add** (optional) `AFTER INSERT/UPDATE/DELETE` NOTIFY triggers, or emit `pg_notify` from services (§ real-time).

Search infrastructure (08_search): 6 generated `fts` columns (:46-76), 6 GIN + 4 btree indexes (:79-95), `SET STATISTICS 10000` (:97-100) — keep unchanged (needs only `unaccent`).

### 4.4 Policies (36), grants, storage

| Object | Lines | Decision |
|---|---|---|
| RLS enable ×11 | 05_policies 7-17 | optional (M8 hardening). If enabled, `crm_app` must not own tables (owner bypasses RLS) |
| 33 table policies, all `TO authenticated`, `using (true)` except configuration `is_admin()` | 05_policies 20-70 | drop; superseded by service RBAC (§3.1); re-express on `app.role` if RLS kept |
| Grants to `anon`/`authenticated`/`service_role`/`postgres` (schema, 14 functions, 11 tables, 4 views, 9 sequences) | 06_grants 7-164 | drop; replace with `GRANT SELECT,INSERT,UPDATE,DELETE` on app tables + `USAGE` on sequences + `EXECUTE` on `global_search`/`merge_contacts` to `crm_app`; `REVOKE ALL ON SCHEMA public FROM PUBLIC` |
| 3 `storage.objects` policies (select/insert/delete, bucket `attachments`) | 07_storage 6-8 | drop → files API |
| Bucket `attachments`, **`public = true`** | `migrations/20240730075029_init_db.sql:555-558` | drop → authenticated streaming |

Supabase dependency summary: `auth.users` (01:173, 02:177, 04:79-85), `auth.uid()` (02:309, 02:489), `auth.jwt()` none, `request.jwt.*`/`request.headers` (02:16, 02:133-138), `storage.*` (07, init_db:555), roles `anon/authenticated/service_role` (05, 06, 08:195-196), `extensions.*` (01:7-8,20,98; 02:69,72,108-109; 08:8,15), `http` (01:7, 02:72,108-109), `pg_net` (02:35; `migrations/20260304104600…:3`, `20260309112831…:340-343`).

## 5. Edge functions (`supabase/functions/`, all `verify_jwt=false` in `config.toml:163-174`, auth done in `_shared/authentication.ts:35-80` via JWKS)

| Function | What it does | I/O | UI call site | Replacement |
|---|---|---|---|---|
| `users` (448 l.) | POST invite (admin only, :133): email uniqueness incl. secondary emails, `user_invitations` row, `auth.admin.createUser`, `inviteUserByEmail`, set disabled/admin. PATCH (:263-420): self-or-admin, email/secondary-email validation (`secondaryEmails.ts`), `updateUserById` + `ban_duration` for disable, avatar | `{email,first_name,last_name,administrator,disabled,…}` → `{data: Sale}`; errors `{message,code,email}` 401/404/409/400 | dataProvider `salesCreate`/`salesUpdate` | `POST/PATCH /api/users` in UserService; keep error codes (`email_taken`, `secondary_email_taken`, `invalid_secondary_email`, `too_many_secondary_emails`, `secondary_email_is_primary`) — UI reads them |
| `update_password` (38 l.) | `resetPasswordForEmail(user.email)` (:8-10) | PATCH `{sales_id}` (ignored; uses caller) → `{data}` | `updatePassword` | `POST /api/auth/password-reset/self` |
| `merge_contacts` (194 l.) | transaction as `authenticated` with injected `sub` (:87-90): reassign tasks/notes, rewrite `deals.contact_ids`, merge fields, delete loser | `{loserId,winnerId}` → `{success,winnerId}` | `mergeContacts` | `POST /api/contacts/:id/merge` + audit + NOTIFY |
| `delete_note_attachments` (107 l.) | called by pg_net trigger; deletes files whose numeric stem is unreferenced in notes/logos/avatars/config (:79-101) | webhook payload | none (DB-driven) | FileService GC: `files` rows with no reference (tracked via `file_refs` or the same text scan) → unlink after grace period |
| `postmark` (393 l. + helpers) | inbound email webhook: Basic auth + IP allowlist (:21-33), matches sender to sales, creates contact/company + note + attachments | Postmark JSON | none; only displays `config.inboundEmail` (`ProfilePage.tsx:240-256`, `SettingsPageMobile.tsx:545-557`) | **out of scope**: requires a public inbound mail provider (external service, real email). Hidden automatically when `inboundEmail` unset |
| `mcp` (581 l.) | MCP server with OAuth, tools `get_schema`, `query`, `mutate` (model-written SQL), `display_task_list`, `complete_task` (:289-540) | MCP/JSON-RPC | MCP URL card shown unconditionally (`ProfilePage.tsx:258-272`, `SettingsPageMobile.tsx:577`); consent page | **out of scope**: arbitrary-SQL surface + OAuth authorization server is disproportionate risk for a showcase. Must remove the MCP card (else it shows a dead `undefined/functions/v1/mcp` URL) |

`_shared/supabaseAdmin.ts:8-10` (service-role key) and `_shared/db.ts:173-175` (`SUPABASE_DB_URL`, falls back to `postgres:postgres`) have no equivalent: the API's single `crm_app` pool replaces both; `_shared/cors.ts:2` (`Access-Control-Allow-Origin: *`) is replaced by same-origin (no CORS).

## 6. Storage

| Flow | Where | Upstream | Replacement |
|---|---|---|---|
| Upload note attachments | `dataProvider.ts:316-337,461-520`; inputs `notes/NoteInputsMobile.tsx:82`, `AttachmentField.tsx:49` | bucket root, name `Math.random()+ext`, public URL in `attachments[].src`, `path`, `type` | `POST /api/files` (multipart, `@fastify/multipart`, limit 50 MiB like `config.toml:66`, MIME sniff + allowlist); stored at `D:\crm-data\files\{yyyy}\{mm}\{uuid}` [path is a proposal] outside web root |
| Upload company logo | `dataProvider.ts:36-50,376-389`; `misc/ImageEditorField.tsx:97-117` (cropper) | same bucket, `logo.src` | same |
| Upload sales avatar | `dataProvider.ts:343-348` | same; also sent to edge fn `users` | same |
| Upload config logos | `dataProvider.ts:295-315` | string URL in `configuration.config` | same |
| Download/view | `NoteAttachments.tsx:32-54` (`href`/`img src`), `CompanyAvatar.tsx:20`, `contacts/Avatar.tsx:33`, `ExportVCardButton.tsx:26` (fetch avatar) | unauthenticated public URL | `GET /api/files/:id` — session cookie required (works for `<img>`/`<a>` same-origin), `Content-Disposition: attachment` for non-images, `nosniff`, `Cache-Control: private` |
| Delete | DB triggers → `delete_note_attachments` | async, best-effort | soft-delete + GC (§5) |
| External URLs | avatars/logos from Gravatar/favicon.show stored as plain URLs | — | keep as-is (no file row) |

Showcase note: URLs are persisted inside JSON (`attachments[].src`, `logo.src`, `avatar.src`, config logos), so the URL format `/api/files/{uuid}` must be stable and relative.

## 7. Configuration / runtime

| Item | Location | Replacement |
|---|---|---|
| `window._atomicCrmConfig` (`RuntimeConfig`) | `root/config.ts:42-58`; loaded by `index.html:33` (`./config.js`) | keep mechanism; new keys: `apiBaseUrl` (default `/api`), `isDemo`, `attachmentsMaxBytes`; remove `supabaseUrl`, `supabasePublishableKey`, `attachmentsBucket`, `inboundEmail`, `googleWorkplaceDomain`, `disableEmailPasswordAuthentication` |
| `scripts/renderRuntimeConfig.ts:15-24` | maps `VITE_SUPABASE_URL`, `VITE_SB_PUBLISHABLE_KEY`, `VITE_IS_DEMO`, `VITE_INBOUND_EMAIL`, `VITE_ATTACHMENTS_BUCKET`, `VITE_GOOGLE_WORKPLACE_DOMAIN`, `VITE_DISABLE_EMAIL_PASSWORD_AUTHENTICATION` | adapt ENV_KEYS to `VITE_API_BASE_URL`, `VITE_IS_DEMO` |
| `.env.development`, `.env.e2e`, `.env.demo` | Supabase URL/keys (local demo keys; `.env.e2e` also has a service-role JWT) | replace; never ship secrets in config.js |
| Server env (new, not public) | — | `CRM_DATABASE_URL` (crm_app), `CRM_MIGRATION_DATABASE_URL`, `CRM_SESSION_SECRET`, `CRM_FILES_DIR`, `CRM_MAIL_DIR`, `CRM_PUBLIC_ORIGIN`, `CRM_COOKIE_SECURE=true`, `CRM_ENRICHMENT_ENABLED=false` — loaded from a protected file, not the repo |
| `getDataProvider` guards | `dataProvider.ts:409-424` | guard only `apiBaseUrl` |

## 8. Tests

| Test | Supabase dependency | Adaptation |
|---|---|---|
| `providers/supabase/dataProvider.test.ts` (globalSearch HttpError status, :19-20) | mocks supabase client | port to new provider with `fetch` mock; keep "401 propagates status" case |
| `providers/supabase/authProvider.test.ts` (logout scope local, cache clearing, signup redirect, :17-45) | mocks `ra-supabase-core` | rewrite for cookie API; keep cache-clear and uninitialized→`/sign-up` cases |
| `providers/supabase/searchDealCategories.test.ts` | none (pure) | move to server unit tests (Node test runner) |
| `components/supabase/oauth-consent-page.test.tsx` | OAuth API | delete with page |
| `providers/fakerest/internal/*.test.ts` (supabaseAdapter, transformFilter/In/Or/Contains) | PostgREST syntax only | keep; reuse cases as server filter-parser contract tests |
| `providers/commons/i18nProvider.test.ts:30-35` | asserts `ra-supabase.auth.password_reset` | update to relocated keys |
| `supabase/functions/**/*.test.ts` (vitest project `functions`, `vitest.config.ts:118-122`) | Deno/jsr aliases | port `users/secondaryEmails.test.ts`, `delete_note_attachments/candidateNames.test.ts` to server; drop `mcp/*`, `postmark/*` |
| E2E `e2e/fixtures.ts` (admin client :2-5, `resetDb` :24-35 incl. `auth.admin.deleteUser`, `createUser` :37-90 via `user_invitations`+`auth.admin.createUser`, direct inserts :111-165) | supabase-js service role | fixtures use `pg` with a test-only owner role: `TRUNCATE … RESTART IDENTITY CASCADE`, insert `app_users` with argon2 hash helper, wipe files dir |
| E2E `e2e/signup.spec.ts:1-20` | `supabase.auth.signUp` | `POST /api/auth/bootstrap` must return 403 once initialized |
| E2E specs (adminAccountManagerFilter, bulkContactTags, createContactFromDeal, globalSearch, onboarding, userAddingATask) | only via fixtures | unchanged UI steps; add RBAC specs (sales_rep forbidden edit, showcase 403), attachment auth spec, SSE spec |
| `makefile:29-81`, `playwright.config.ts:33` (baseURL `:5175`) | Supabase CLI e2e instance | PowerShell script: create `crm_e2e` DB, run migrations, start API + `vite preview` |

## 9. Feature parity checklist

| Feature | UI | Status |
|---|---|---|
| Login / logout / session | LoginPage, authProvider | **PoC** |
| Companies CRUD + list search/filters + summary counts | companies/* | **PoC** (list/show/create); M4 rest |
| Contacts CRUD + filters (`last_seen`, tags, `nb_tasks`, status, account manager) | contacts/* | **PoC** (list/show/create); M4 rest |
| Deals kanban (drag/drop reindex), archive/unarchive, categories filter | deals/* | **M4** (add `POST /api/deals/reorder` transactional) |
| Tasks (create/done/due-date lists) | tasks/* | M4 |
| Notes with attachments (contact + deal) | notes/* | **PoC** (upload + authenticated download), GC in M4 |
| Tags (CRUD, bulk tag, delete cleanup trigger) | tags/*, BulkTagButton | M4 |
| Global search (`global_search`) | search/GlobalSearchButton | M4 (SQL ported unchanged) |
| Dashboard widgets (DealsChart, DealsPipeline, HotContacts, LatestNotes, tasks) | dashboard/* | M4 |
| Activity log (view + infinite list) | activity/* | M4; **live updates via SSE** M4 (net-new; upstream has no realtime) |
| CSV import (companies, deals, contacts) and JSON import (`ImportPage`, incl. sales via `salesCreate`) | dataImport/*, misc/useImportFromJson.ts | M4 (row-by-row create; add server batch later if slow) |
| Export CSV / vCard | ContactList exporter, ExportVCardButton | M4 (client-side; needs `getMany`) |
| Merge contacts | ContactMergeButton | M4 |
| User management / invitations / disable | sales/* | M4 (invite mail → outbox log) |
| Settings / configuration (stages, categories, logos, title) | SettingsPage | M4 |
| Profile edit, secondary emails, avatar | ProfilePage | M4 |
| Password reset (forgot) / set password / invite acceptance | forgot/set-password pages | **PoC** for reset via log; M4 polish |
| In-app password change | — (upstream sends reset mail) | M4 (small addition) |
| First-user sign-up | SignupPage | M4 (or seeded admin; decision) |
| Read-only showcase visitor role | — (net-new) | M4 |
| Audit log | — (net-new) | M4 (admin read endpoint) |
| SSO (SAML / Google Workspace) | SSOAuthButton, auth-callback.html | out-of-scope: requires external IdP; hidden when `googleWorkplaceDomain` unset |
| MCP server + OAuth consent page | ProfilePage MCP card, OAuthConsentPage | out-of-scope: arbitrary SQL surface, OAuth server; **card must be removed** |
| Inbound email → notes (Postmark) | ProfilePage inbound card | out-of-scope: needs external inbound mail service; card hidden when unset |
| Gravatar/favicon auto-enrichment | DB triggers | out-of-scope by default (outbound calls, privacy); optional flag M4 |
| Demo mode (FakeRest) | `isDemo` | unchanged (no backend) |

## 10. Effort and risk

**Size.** Frontend: 2 providers (~600 LOC replacing 520+178), 3 auth pages rewritten, ~6 small UI edits (MCP/inbound cards, SSO, i18n keys, canAccess roles, config). Backend: ~32 endpoints — generic CRUD over 11 resources (one parametrised router + per-resource whitelist/policy), auth (login, logout, me, init-state, bootstrap, reset request/confirm, self-reset, change-password, csrf), users (2), configuration (2), files (2), search (1), merge (1), unarchive (1), reorder (1), events SSE (1), audit (1), health (1). SQL: 11 tables kept/adapted + 7 new; 3 views kept, 1 dropped; 9 functions kept/adapted (search ×5, merge_contacts, lowercase_email_jsonb, handle_tag_deleted, contact-note last_seen), 11 dropped or moved to services; 4 of 17 triggers kept; all 36 policies and all Supabase grants dropped. Estimate [inferred]: PoC 4–6 dev-days; full M4 parity incl. tests 12–18 dev-days.

**Top 5 risks**

1. **Filter/sort grammar drift.** Lists silently break if the server parser misses an operator or literal form (`{1}`, `(a,b)`, `@not.is`). Mitigate: whitelist parser + contract tests reusing FakeRest adapter cases; 400 on unknown keys (never ignore).
2. **Auth security owned by us.** Session fixation, CSRF on cookie auth, enumeration via reset/invite, brute force, token leakage in logs. Mitigate: rotate session id on login, `SameSite=Lax` + CSRF header + `Origin` check on mutating requests, uniform 202 on reset, hashed single-use tokens, rate limit, argon2id params tuned for the RAM-limited host (scrypt fallback if `argon2` native build fails on Windows).
3. **Record-level RBAC vs. existing UX.** Upstream lets anyone edit anything; client code does multi-row writes on other owners' rows (kanban reindex `DealListContent.tsx:130-240`, `unarchiveDeal`, merge, bulk tag). Strict ownership would break these. Mitigate: dedicated server endpoints for reorder/unarchive/merge with explicit rules; decide manager vs. rep scope before M4.
4. **Attachment migration and auth.** Upstream files are public URLs embedded in JSON; new files require cookies. `<img>`/`<a>` work same-origin, but vCard export fetch and any cross-origin use break; path traversal / content-type sniffing / disk-fill risks on Windows. Mitigate: uuid-only names, size + MIME limits, `nosniff`, quota, GC with grace period.
5. **Behaviour previously hidden in triggers and Supabase internals.** `sales_id` defaulting, email lowercasing, last_seen, tag cleanup, first-user-is-admin, disabled = GoTrue ban, plus SSE needing a dedicated LISTEN connection that survives pool recycling and PG restarts. Mitigate: services own each rule with unit tests; SSE with heartbeat, reconnect + `Last-Event-ID`, per-client RBAC filtering of events.
