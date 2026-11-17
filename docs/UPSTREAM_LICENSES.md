# Upstream Licenses & Attribution

> M0 entries reflect the owner's directive. Each will be confirmed against the upstream `LICENSE` file at the pinned revision during M1 (column "Verified").

| Upstream | Repository | License | Verified | Obligations for this repo |
|---|---|---|---|---|
| Atomic CRM | https://github.com/marmelab/atomic-crm | MIT | ✅ `LICENSE.md` "Copyright (c) 2024-present, Francois Zaninotto, Marmelab" | Keep copyright + license notice in any distributed copy. |
| ERPNext | https://github.com/frappe/erpnext | GPL-3.0 | ✅ `license.txt`, `package.json`, GitHub API | Extensions that link against ERPNext are GPL-3.0; provide source for deployed modifications; keep notices. Respect `TRADEMARK_POLICY.md`. |
| Frappe Framework | https://github.com/frappe/frappe | MIT | ✅ GitHub API | Keep notices. |
| frappe_docker | https://github.com/frappe/frappe_docker | MIT | ✅ GitHub API | Keep notices. |
| NexoPOS | https://github.com/Blair2004/NexoPOS | GPL-3.0 | ✅ `LICENSE` + GitHub API. ⚠ `composer.json` says "MIT" — upstream inconsistency; we follow the stricter GPL-3.0 LICENSE file. | NexoPOS modules are GPL-3.0; source for deployed modifications is public here; keep notices. |
| erpnext_demo_gen (design reference only) | https://github.com/thava/erpnext_demo_gen | GPL-3.0 | ✅ GitHub API | If any code is adapted, it goes under the GPL-3.0 ERP directory with attribution. |
| Supabase (self-host components) | https://github.com/supabase/supabase | Apache-2.0 (expected) | pending (M1) | Keep notices. |
| Caddy | https://github.com/caddyserver/caddy | Apache-2.0 | pending (M3) | Configuration only; no redistribution. |

## Trademarks

"ERPNext", "Frappe", "NexoPOS", "Atomic CRM", and "Supabase" are names of their respective owners. This portfolio uses them only to identify the upstream software; it does not claim affiliation or endorsement, and the portal must state that the upstream products were authored by their respective projects.

## License boundary in this repository

| Path | License |
|---|---|
| `/` (default, original work) | MIT — root `LICENSE` |
| `apps/erp/customization/**` | GPL-3.0 — own `LICENSE` (added with first code, M5) |
| `apps/pos/customization/**` | GPL-3.0 — own `LICENSE` (added with first code, M6) |
| `apps/crm/**` | MIT (upstream is MIT; notice retained) |
