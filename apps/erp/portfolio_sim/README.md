# portfolio_sim

Custom Frappe app for ERPNext v16.60.0 (GPL-3.0). It simulates *Sable Ridge Electronics Supply Co.*, a fictional
B2B wholesale electronics distributor, through ERPNext's own document lifecycle: purchasing, receiving, billing,
payments, selling with partial deliveries, invoicing, returns, credit and debit notes, reconciliation, stock
transfers and counts, and expenses. Execution is deterministic and exactly-once, and checked by integrity and
replay verification.

```bash
bench get-app portfolio_sim <path or repository>
bench --site <site> install-app portfolio_sim
bench --site <site> portfolio-sim setup
bench --site <site> portfolio-sim backfill --until "2025-09-30 23:59:59"
bench --site <site> portfolio-sim integrity
bench --site <site> portfolio-sim replay-check
```

All companies, people and transactions are fictional. Design and verification status: see `docs/ERP_DATA_ENGINE.md`
in the portfolio repository.
