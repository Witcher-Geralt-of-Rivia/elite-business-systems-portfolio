# Roadmap

Milestones are sequential. A milestone is complete only when its acceptance criterion has evidence in `docs/TEST_RESULTS.md`.

| ID | Milestone | Acceptance | Status |
|---|---|---|---|
| M0 | GitHub repository creation | Public repo + initial tracking commit independently verifiable | **done** |
| M1 | Upstream project audit | Documented approach per app with real source references, pinned revisions, license confirmation | **done** |
| M2 | Windows VPS compatibility audit | Verified deployment method, or documented blocker with evidence | **done** (D-008, D-009; ERP reboot pending separate approval) |
| M3 | Infrastructure foundation | Minimal service reachable via intended sslip.io HTTPS route; logging, backups, health checks | **done** for CRM (HTTPS, logs, nightly backup with restore check, health endpoint); POS/ERP added per milestone |
| M4 | CRM implementation | Working CRM, consistent persisted data, live activity, passing E2E (CRM-W) | **done** (2026-11-17, public E2E 10/10; one observation pending: first live lead in a production business window) |
| M5 | ERP implementation | Working ERP, reconciled transactions, passing E2E (ERP-W) | on hold (Windows runtime needs an unapproved reboot) |
| M6 | POS implementation | Working POS, transactional persistence, working reports, passing E2E (POS-W) | **locally accepted** (2026-11-18: 12-month dataset, 43/43 integrity, live worker, E2E 8/8 + 4/4); public HTTPS awaits owner approval |
| M7 | Portfolio portal | Professional responsive portal linking to working apps | **deployed** (2026-11-18): live CRM link and status; POS shown as "being finalised" until approved; ERP "in preparation" |
| M8 | Security, integration, performance | No unresolved critical security/deployment/core-workflow failures | not started |
| M9 | Final delivery | All claims backed by commits, test evidence, operational checks | not started |

Resource note: the host's measured headroom (see ARCHITECTURE §3) may require a staged-activation strategy for M4–M6 (X-RES-1). That decision is made in M2 with measurements.
