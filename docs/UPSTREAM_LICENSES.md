# Upstream Licenses & Attribution

> Licences were confirmed against the upstream `LICENSE` files at the pinned revisions during M1 (column "Verified").
> The licence boundary table at the end reflects Release 1.0 (2026-11-18).

| Upstream | Repository | License | Verified | Obligations for this repo |
|---|---|---|---|---|
| Atomic CRM | https://github.com/marmelab/atomic-crm | MIT | ✅ `LICENSE.md` "Copyright (c) 2024-present, Francois Zaninotto, Marmelab" | Keep copyright + license notice in any distributed copy. |
| ERPNext | https://github.com/frappe/erpnext | GPL-3.0 | ✅ `license.txt`, `package.json`, GitHub API | Extensions that link against ERPNext are GPL-3.0; provide source for deployed modifications; keep notices. Respect `TRADEMARK_POLICY.md`. |
| Frappe Framework | https://github.com/frappe/frappe | MIT | ✅ GitHub API | Keep notices. |
| frappe_docker | https://github.com/frappe/frappe_docker | MIT | ✅ GitHub API | Keep notices. |
| NexoPOS | https://github.com/Blair2004/NexoPOS | GPL-3.0 | ✅ `LICENSE` + GitHub API. ⚠ `composer.json` says "MIT" — upstream inconsistency; we follow the stricter GPL-3.0 LICENSE file. | NexoPOS modules are GPL-3.0; source for deployed modifications is public here; keep notices. |
| erpnext_demo_gen (design reference only) | https://github.com/thava/erpnext_demo_gen | GPL-3.0 | ✅ GitHub API | If any code is adapted, it goes under the GPL-3.0 ERP directory with attribution. |
| Supabase (self-host components) | https://github.com/supabase/supabase | Apache-2.0 | n/a | **Not used.** Removed from the CRM (D-009); no Supabase code or packages in this repository. |
| Caddy | https://github.com/caddyserver/caddy | Apache-2.0 | pending (M3) | Configuration only; no redistribution. |

## Trademarks

"ERPNext", "Frappe", "NexoPOS", "Atomic CRM", and "Supabase" are names of their respective owners. This portfolio uses them only to identify the upstream software; it does not claim affiliation or endorsement, and the portal must state that the upstream products were authored by their respective projects.

## License boundary in this repository

| Path | License |
|---|---|
| `/` (default, original work) | MIT — root `LICENSE` |
| `apps/erp/portfolio_sim/**` (custom Frappe app for ERPNext) | GPL-3.0, own `license.txt` (GPL v3 text, as distributed with ERPNext) |
| `apps/erp/tests/**`, `scripts/verification/check_erp_upstream.py` | MIT (original test and verification code; no ERPNext code imported) |
| `apps/pos/modules/HarborPine/**` | GPL-3.0, own `LICENSE` (NexoPOS module) |
| `apps/pos/e2e/**` | MIT (original test code) |
| `apps/crm/frontend/**` | MIT. Atomic CRM snapshot `22f38f0f`; upstream `LICENSE.md` retained ("Copyright (c) 2024-present, Francois Zaninotto, Marmelab") |
| `apps/crm/backend/**` | MIT (original work) |

Release 1.0 review (2026-11-18): the CRM runtime dependency trees contain only permissive licences, plus OFL-1.1
(Inter font), MPL-2.0/Apache-2.0 (DOMPurify) and MPL-2.0 (lightningcss, an unmodified build tool). There is no GPL or
AGPL code in the MIT parts. NexoPOS's own dependencies are installed on the host, not redistributed here.
See [TEST_RESULTS M8 §8](TEST_RESULTS.md#m8--integration-performance-and-operational-validation-2026-11-18-public-pos).
