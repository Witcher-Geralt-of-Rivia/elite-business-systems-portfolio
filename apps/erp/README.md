# ERP — `portfolio_sim` (custom Frappe app for ERPNext v16.60.0)

GPL-3.0 ([portfolio_sim/license.txt](portfolio_sim/license.txt)), because it extends ERPNext. It simulates the
fictional wholesale distributor *Sable Ridge Electronics Supply Co.* through ERPNext's own document lifecycle.

**Status:** implemented. **Not yet run on ERPNext** (no runtime on the Windows host until the WSL1 proof of
concept is approved). Design and evidence: [docs/ERP_DATA_ENGINE.md](../../docs/ERP_DATA_ENGINE.md); runtime
plan: [docs/runbooks/ERP_WSL1_POC.md](../../docs/runbooks/ERP_WSL1_POC.md).

```text
portfolio_sim/
  pyproject.toml, license.txt
  portfolio_sim/
    hooks.py                 required_apps, after_install, scheduler (live worker tick)
    commands.py              bench portfolio-sim setup|backfill|status|integrity|replay-check|live|pause|resume
    upstream_refs.py         every ERPNext/Frappe function, method, account and fixture relied on
    data/catalog.json        497 curated source values
    engine/                  pure Python: rng, calendar, scenario, planner (no Frappe imports)
    services/                setup, executor (ERPNext mappers + submit), simulator (exactly-once), integrity, worker
    distribution_simulation/ DocTypes: Distribution Sim Event (ledger), Distribution Sim Settings (single)
    tests/test_lifecycle.py  ERPNext integration tests (written, not yet executed)
tests/                       engine and static tests runnable without Frappe
```

## Verify without ERPNext

```powershell
# pinned sources for the static checks (git-ignored)
git clone --depth 1 --branch v16.60.0 https://github.com/frappe/erpnext.git upstream/erpnext-v16.60.0
git clone --depth 1 --branch v16.60.0 https://github.com/frappe/frappe.git  upstream/frappe-v16.60.0

python -m unittest discover -s apps/erp/tests -v          # engine + static (Python 3.12+)
python scripts/verification/check_erp_upstream.py          # references vs pinned sources
```

## Install on a bench (after the runtime exists)

```bash
bench get-app portfolio_sim /path/to/elite-business-systems-portfolio/apps/erp/portfolio_sim
bench --site <site> install-app erpnext
bench --site <site> install-app portfolio_sim
bench --site <site> portfolio-sim setup
bench --site <site> portfolio-sim backfill            # resumable; history up to now
bench --site <site> portfolio-sim integrity && bench --site <site> portfolio-sim replay-check
bench --site <site> portfolio-sim live on             # scheduler continues the business every minute
```
