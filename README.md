# Elite Business Systems Portfolio

Enterprise-grade CRM, ERP, and POS showcase applications featuring independent business databases, realistic synthetic operations, live analytics, and VPS deployment infrastructure.

> **Status:** early development — see [docs/PROGRESS.md](docs/PROGRESS.md) and [state/checkpoint.json](state/checkpoint.json) for the verified current state. Nothing below is claimed as working until it appears in [docs/TEST_RESULTS.md](docs/TEST_RESULTS.md).

## What this is

Three independent business applications, each built on an established open-source product, customized and populated with fictional but internally consistent business activity:

| Application | Built on | Fictional business | Database |
|---|---|---|---|
| CRM | [Atomic CRM](https://github.com/marmelab/atomic-crm) (MIT) | B2B technology services company | PostgreSQL (Supabase architecture) |
| ERP | [ERPNext](https://github.com/frappe/erpnext) (GPL-3.0) | Multi-warehouse electronics distributor | MariaDB (Frappe framework) |
| POS | [NexoPOS](https://github.com/Blair2004/NexoPOS) (GPL-3.0) | Specialty retail store | MySQL/MariaDB (Laravel) |

Plus a client-facing **portfolio portal** that presents and links to the three applications.

## Honesty statement

- The underlying products were created by their upstream authors, not by this portfolio's owner. This repository contains customizations, synthetic-data engines, deployment infrastructure, and the portal.
- **All business data is synthetic.** Every company, person, product, and transaction is fictional. No real customer data is used, and none of these environments represent work delivered to a paying client.
- Email addresses use reserved domains (`example.com`/`.org`/`.net`), phone numbers use fictional ranges, and payments are simulated — no real payment gateway is ever called.

## Repository layout

```text
apps/{crm,erp,pos}/   customization, simulation, migrations, tests, deployment per app
portal/               client-facing showcase site
infrastructure/       Windows host, Linux runtime, proxy, containers, monitoring, backups
scripts/              provisioning, verification, maintenance
docs/                 specification, architecture, decisions, risks, progress, test evidence
state/checkpoint.json machine-readable project state (resume point)
```

Upstream source code is **not** vendored into this repository; it is referenced at pinned revisions (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).

## Licensing

This repository mixes components under different licenses. See [docs/UPSTREAM_LICENSES.md](docs/UPSTREAM_LICENSES.md). In short: original portfolio components are MIT ([LICENSE](LICENSE)); anything that extends ERPNext or NexoPOS is GPL-3.0 and lives under directories marked with their own `LICENSE` file.
