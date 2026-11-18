# Elite Business Systems Portfolio

Customised open-source business applications (a CRM and a point of sale, with an ERP in preparation),
each deployed with its own database, a year of fictional synthetic history and a live simulation that keeps
generating business activity.

> **Release 1.0 — CRM + POS + Portal (2026-11-18).** The CRM, the POS and the portfolio portal are deployed over
> HTTPS and verified ([docs/FINAL_DELIVERY.md](docs/FINAL_DELIVERY.md)). **The ERP is not part of this release**:
> it is an outstanding milestone (on hold), so the CRM/ERP/POS project as a whole is not finished. Every claim is
> backed by evidence in [docs/ACCEPTANCE_MATRIX.md](docs/ACCEPTANCE_MATRIX.md) and [docs/TEST_RESULTS.md](docs/TEST_RESULTS.md).

## What this is

| Application | Built on (upstream author, licence) | Fictional business | Stack | Status |
|---|---|---|---|---|
| CRM | [Atomic CRM](https://github.com/marmelab/atomic-crm) (Marmelab, MIT) | *Meridian Advisory*, B2B operations-analytics software and services | Atomic CRM UI + project-built Fastify API, PostgreSQL 16 | **live**, read-only visitor demo |
| POS | [NexoPOS](https://github.com/Blair2004/NexoPOS) v6.3.0 (Blair Jersyer, GPL-3.0) | *Harbor & Pine Market*, coastal specialty food and home store | NexoPOS (Laravel, PHP 8.3) + a GPL-3.0 module, MariaDB 11.8 | **live**, read-only visitor demo with checkout preview |
| ERP | [ERPNext](https://github.com/frappe/erpnext) v16 (Frappe Technologies, GPL-3.0) | wholesale electronics distributor | Frappe/ERPNext (planned) | **on hold**: research, pins and runbook done; not implemented. The runtime needs an owner-approved Windows change |
| Portal | original work (MIT) | — | static site behind Caddy | **live**, with live application status |

Public hostnames follow `https://{portfolio,crm,pos}.<server-ip>.sslip.io`; the address is published on the portal,
not in this repository.

## Honesty statement

- **Not original products.** The CRM and POS are established open-source products created by their upstream
  authors. This repository contains:
  - the customisations;
  - the CRM's own API, which replaces upstream's Supabase backend;
  - a NexoPOS module;
  - two synthetic-data engines;
  - deployment, operations and test tooling;
  - the portal.
- **All business data is synthetic.** Every company, person, product and transaction is fictional. No real
  customer data is used, and none of these environments is work delivered to a paying client.
- **Fictional contact data.** E-mail addresses use reserved domains (`.example`), phone numbers use fictional
  ranges, and payments are simulated. No real payment gateway is ever called.

## Highlights

- **Simulated, not seeded.** Records are the consequences of business events, written through each application's own
  services (validation, permissions, audit). History: CRM 13 months, POS 12 months (24,000+ orders).
- **Deterministic and exactly-once.**
  - Seeded engines with persisted state; replay checks prove the history matches the plan.
  - The POS idempotency ledger survives restarts, crashes and concurrent workers.
- **Checked continuously.** 22 CRM and 43 POS integrity checks, all at zero on production at release.
- **Tested.** CRM backend 42/42 and public browser suite 10/10; POS admin workflow 9/9 on an isolated clone and
  public visitor suite 4/4 (desktop and phone).
- **Operated.** Least-privilege Windows services, nightly backups with restore checks, health monitoring with
  event-log alerts, staged dependency updates with rollback.

## Documentation

| Document | Content |
|---|---|
| [FINAL_DELIVERY.md](docs/FINAL_DELIVERY.md) | release scope, functionality, architecture, results, outstanding items |
| [ACCEPTANCE_MATRIX.md](docs/ACCEPTANCE_MATRIX.md) | claims and requirements mapped to evidence |
| [OPERATIONS_HANDBOOK.md](docs/OPERATIONS_HANDBOOK.md) · [RECOVERY_GUIDE.md](docs/RECOVERY_GUIDE.md) | running, maintaining and recovering the deployment |
| [KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md) | what is not done or deliberately constrained |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) · [DEPLOYMENT.md](docs/DEPLOYMENT.md) · [DECISIONS.md](docs/DECISIONS.md) · [RISKS.md](docs/RISKS.md) | design, host layout, decisions, risks |
| [CRM_DATA_ENGINE.md](docs/CRM_DATA_ENGINE.md) · [POS_DATA_ENGINE.md](docs/POS_DATA_ENGINE.md) | the two data engines |
| [TEST_RESULTS.md](docs/TEST_RESULTS.md) · [PROGRESS.md](docs/PROGRESS.md) · [state/checkpoint.json](state/checkpoint.json) | evidence, history, machine-readable state |

## Repository layout

```text
apps/crm/frontend/         Atomic CRM snapshot @22f38f0f (MIT, notice retained) wired to the project API
apps/crm/backend/          Fastify API, migrations, CRM data engine, tests
apps/pos/modules/HarborPine/  NexoPOS module (GPL-3.0): store, retail engine, live worker, visitor mode, checks
apps/pos/e2e/              Playwright suites for the POS (isolated admin, public visitor)
portal/site/               portfolio portal (static)
infrastructure/            Caddy site templates, Windows service definitions
scripts/                   provisioning, maintenance (backups, monitor), verification
docs/                      specification, architecture, decisions, risks, evidence, delivery package
```

Upstream source code is **not** vendored. NexoPOS and ERPNext are referenced at pinned revisions
([docs/UPSTREAM_AUDIT.md](docs/UPSTREAM_AUDIT.md)); the Atomic CRM frontend is a pinned snapshot with its MIT licence.

## Security note

The host had a historical malware incident (R-014, [docs/SECURITY_INVESTIGATION.md](docs/SECURITY_INVESTIGATION.md),
sanitised). Application tests and dependency audits do not establish that the host is remediated. Credential
rotation and host remediation are open owner actions.

## Licensing

This repository mixes licences; see [docs/UPSTREAM_LICENSES.md](docs/UPSTREAM_LICENSES.md).
- Original portfolio components are MIT ([LICENSE](LICENSE)).
- The NexoPOS module is GPL-3.0 (`apps/pos/modules/HarborPine/LICENSE`).
- The Atomic CRM snapshot keeps its MIT licence (`apps/crm/frontend/LICENSE.md`).
- Product names belong to their owners; no affiliation or endorsement is implied.
