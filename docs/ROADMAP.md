# Roadmap

Milestones are sequential. A milestone is complete only when its acceptance criterion has evidence in `docs/TEST_RESULTS.md`.

| ID | Milestone | Acceptance | Status |
|---|---|---|---|
| M0 | GitHub repository creation | Public repo + initial tracking commit independently verifiable | **done** |
| M1 | Upstream project audit | Documented approach per app with real source references, pinned revisions, license confirmation | **done** |
| M2 | Windows VPS compatibility audit | Verified deployment method, or documented blocker with evidence | **done** (D-008, D-009; ERP reboot pending separate approval) |
| M3 | Infrastructure foundation | Minimal service reachable via intended sslip.io HTTPS route; logging, backups, health checks | **done** for CRM (HTTPS, logs, nightly backup with restore check, health endpoint); POS/ERP added per milestone |
| M4 | CRM implementation | Working CRM, consistent persisted data, live activity, passing E2E (CRM-W) | **done** (2026-11-17, public E2E 10/10; first live lead in a production business window observed 2026-11-18) |
| M5 | ERP implementation | Working ERP, reconciled transactions, passing E2E (ERP-W) | **in progress**: custom Frappe app `portfolio_sim` and distribution engine; ERPNext integration tests **7/7 on Linux** (GitHub Actions: 3,068 events, 36 integrity checks at 0, replay exact). Not deployed on the host; WSL1 untested and blocked on the owner's REBOOT decision ([PoC plan](runbooks/ERP_WSL1_POC.md)) |
| M6 | POS implementation | Working POS, transactional persistence, working reports, passing E2E (POS-W) | **done — publicly deployed and verified** (2026-11-18, D-017: 12-month dataset, 43/43 integrity, live worker, E2E admin 8/8 on a clone + public visitor 4/4, backup/restore verified) |
| M7 | Portfolio portal | Professional responsive portal linking to working apps | **done** (2026-11-18): live CRM and POS links with live status; ERP "in preparation"; no contact section yet (KNOWN_LIMITATIONS L13) |
| M8 | Security, integration, performance | No unresolved critical security/deployment/core-workflow failures | **technically complete for CRM + POS + portal** (2026-11-18: no open deployment or core-workflow failures; dependency audits clean; monitoring live). Still open, owner-side: host incident R-014 (credential rotation/remediation, SEC-ROTATE). ERP is covered when M5 resumes |
| M9 | Final delivery | All claims backed by commits, test evidence, operational checks | **done for Release 1.0 (CRM + POS + portal)**, 2026-11-18 (D-018; [ACCEPTANCE_MATRIX](ACCEPTANCE_MATRIX.md)). ERP delivery remains with M5 |

Resource note: the host's measured headroom (see ARCHITECTURE §3) may require a staged-activation strategy for M4–M6 (X-RES-1). That decision is made in M2 with measurements.
