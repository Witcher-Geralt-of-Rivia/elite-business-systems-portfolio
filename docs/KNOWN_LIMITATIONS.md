# Known Limitations — Release 1.0 (CRM + POS + Portal)

What Release 1.0 does not do, does not guarantee, or limits on purpose. Items marked **owner** need a decision or
action from the owner.

## Scope

| # | Limitation | Detail |
|---|---|---|
| L1 | **ERP not delivered** | ERPNext (M5) is on hold. Frappe v16 has no native Windows runtime; the host has no nested virtualisation, so WSL1 is the only path, and it needs the WSL feature and a Windows reboot (**owner: REBOOT**). Research, pins (v16.60.0) and the runbook are preserved ([FINAL_DELIVERY.md §6](FINAL_DELIVERY.md#6-outstanding-erp-milestone-m5)). The project as a whole is not complete |
| L2 | Showcase, not a commercial service | Fictional businesses and synthetic data; payments simulated; no SLA. Not delivered to, or used by, a real client |

## Security

| # | Limitation | Detail |
|---|---|---|
| L3 | **Host incident open (R-014)** | The VPS executed an information-stealer loader on 2026-10-07. Application tests and audits say nothing about the host's integrity. Credential rotation from a trusted device and host remediation or rebuild are pending (**owner: SEC-ROTATE**); Defender hardening gaps are tracked as R-015 |
| L4 | POS CSP has no `script-src` | NexoPOS relies on inline scripts. Only non-script directives are set (`frame-ancestors`, `object-src`, `base-uri`, `form-action`), plus HSTS and the other headers. The CRM and portal have strict script policies |
| L5 | POS rate limiting answers 500 | NexoPOS's API throttle (80 requests/min per client) returns HTTP 500 "Too Many Attempts" instead of 429. Normal browsing stays far below it; it is kept because it protects the shared demo |
| L6 | Public visitors share one dataset | Both apps are read-only for visitors, so they cannot damage data or see each other's changes, but they cannot try write workflows on the live data. The POS shows a checkout preview instead of saving |
| L7 | No automated pre-push secret hook | Secrets and host details are kept out of the repository by a manual staged-diff scan before every push (a documented practice, not a git hook) |

## Application scope

| # | Limitation | Detail |
|---|---|---|
| L8 | CRM reporting depth | Atomic CRM has dashboards, a pipeline and lists, but no dedicated forecasting or team-performance reports. Meetings are recorded as deal notes of type "Meeting", not as a calendar |
| L9 | CRM-W browser coverage | The complete lead → won lifecycle is exercised by the engine through the service layer (integrity-checked, and observed live in production). Browser tests cover CRUD, search, merge, attachments, invitations and SSE, but not one single deal through every stage in the UI |
| L10 | CRM email | The CRM sends no email: invitation and password links are shown to the administrator as one-time links |
| L11 | POS upstream quirks absorbed by the module | An installed-state race, telemetry, onboarding tours and a translation-file permission are handled by the module or provisioning without patching NexoPOS core ([POS_DATA_ENGINE.md](POS_DATA_ENGINE.md#upstream-behaviour-adjusted-by-the-module-no-core-patches)). A future NexoPOS upgrade must re-verify them |
| L12 | POS UI timing | Two upstream UI timing branches (an early category click; "Select Customer" on Pay) can appear to real users as a click with no effect or an extra customer prompt. Tests handle them; upstream behaviour is unchanged |
| L13 | Portal has no contact section | The specification's "contact" item is not implemented; the owner has not chosen a public contact channel (**owner**) |

## Operations

| # | Limitation | Detail |
|---|---|---|
| L14 | No off-host backups | Nightly dumps (14 days) stay on the VPS. They protect against application and data errors, not against losing or compromising the host (**owner**: copy dumps elsewhere if needed) |
| L15 | Production restore not rehearsed | Every backup is restored nightly into a scratch database, but replacing a production database (RECOVERY_GUIDE §3.2/3.3) has not been rehearsed |
| L16 | Alerts are local only | The monitor writes JSON logs and Windows events; no e-mail or push notification is sent (no paid services). Someone has to look (OPERATIONS_HANDBOOK §4) |
| L17 | Shared, small host | 3 vCPU and 12 GB RAM, shared with the owner's interactive tooling and a co-hosted application. Interactive tools use most of the RAM (R-013). POS pages take about 0.34 s because of PHP-CGI framework boot |
| L18 | POS maintenance windows | The PHP dependency update and a production database restore need about 1 minute of POS downtime (PHP workers stopped) |
| L19 | sslip.io hostnames | Free wildcard DNS bound to the server's IP: an IP change means new hostnames and certificates. Let's Encrypt rate limits apply (R-007) |
| L21 | NexoPOS scheduler not running | `artisan schedule:run` is not scheduled on the host. NexoPOS's 13 periodic jobs therefore do not run, among them low-stock detection, hold-order cleanup, scheduled transactions, combined stock-history upkeep and the daily vendor update check. Reports stay correct because the module recomputes them. Several jobs modify data the engine manages, so enabling the scheduler needs a job-by-job review on a clone first |
| L20 | Pinned upstreams | Atomic CRM snapshot `22f38f0f` and NexoPOS v6.3.0 are pinned. Upstream fixes are not picked up automatically; PHP dependencies get security updates inside upstream's constraints (DEPLOYMENT.md) |
