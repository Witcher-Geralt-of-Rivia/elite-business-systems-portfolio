# Roadmap

Milestones are sequential. A milestone is complete only when its acceptance criterion has evidence in `docs/TEST_RESULTS.md`.

| ID | Milestone | Acceptance | Status |
|---|---|---|---|
| M0 | GitHub repository creation | Public repo + initial tracking commit independently verifiable | **done** |
| M1 | Upstream project audit | Documented approach per app with real source references, pinned revisions, license confirmation | **done** |
| M2 | Windows VPS compatibility audit | Verified deployment method, or documented blocker with evidence | **done** (D-008, D-009; ERP reboot pending separate approval) |
| M3 | Infrastructure foundation | Minimal service reachable via intended sslip.io HTTPS route; logging, backups, health checks | **partial** — HTTPS route verified; scripts pending |
| M4 | CRM implementation | Working CRM, consistent persisted data, live activity, passing E2E (CRM-W) | not started |
| M5 | ERP implementation | Working ERP, reconciled transactions, passing E2E (ERP-W) | not started |
| M6 | POS implementation | Working POS, transactional persistence, working reports, passing E2E (POS-W) | not started |
| M7 | Portfolio portal | Professional responsive portal linking to working apps | not started |
| M8 | Security, integration, performance | No unresolved critical security/deployment/core-workflow failures | not started |
| M9 | Final delivery | All claims backed by commits, test evidence, operational checks | not started |

Resource note: the host's measured headroom (see ARCHITECTURE §3) may require a staged-activation strategy for M4–M6 (X-RES-1). That decision is made in M2 with measurements.
