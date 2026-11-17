# Deployment

> Status: **not yet deployable.** The deployment method is decided in M2 (see `docs/RISKS.md` R-001..R-006). This file will become the step-by-step runbook.

## Target hostnames (sslip.io, no domain purchase)

```text
https://portfolio.<VPS_IP>.sslip.io
https://crm.<VPS_IP>.sslip.io
https://erp.<VPS_IP>.sslip.io
https://pos.<VPS_IP>.sslip.io
```

`<VPS_IP>` is supplied at deploy time via the `PUBLIC_IP` environment variable; it is not committed.

## Operating constraints

- The host already runs a Caddy reverse proxy for unrelated sites. Portfolio routes are added as separate, imported site blocks; the existing configuration is backed up first and validated before reload.
- Databases bind to loopback only. No database or admin port is exposed publicly.
- Remote access (RDP/SSH) and firewall rules are never altered in ways that could lock out the owner.

## Runbook

_TBD (M3)._

## Backup & restore

_TBD (M3–M6), per application._

## Recovery

_TBD (M3)._
