# CRM data engine

Synthetic but **coherent** operational data for the CRM: every record is the consequence of a
simulated business event, written through the API's own service layer (validation, constraints,
audit log), and the same model keeps running live on the server after the history is generated.

Code: `apps/crm/backend/src/simulation/` · CLI: `apps/crm/backend/scripts/simulate.ts` ·
Tests: `apps/crm/backend/test/simulation.test.ts`

## Scenario

*Meridian Advisory* — a fictional firm selling operations-analytics software and services
(8 product lines, $7.5k–$54k list price) to mid-market US companies. Six simulated team members
(one manager, five reps) cover four regions with different capacity and skill. The real
administrator account is never simulated. All companies, people, domains (`.example`) and phone
numbers (`555-01xx`) are invented.

## Curated source values (~500, `catalog.json`)

Team, 8 deal categories (price, spread, sales-cycle length, weight), 11 sectors (stems, kinds,
descriptions), 4 company-size bands (revenue, deal-size factor), 40 cities in 4 regions, 72 first
names (with gender), 80 last names, 24 job titles (seniority, decision-maker flag), lead sources,
pain points, tags, deal-name patterns, note and task templates per sales stage, loss and delay
reasons. A test asserts the count stays in the 450–600 range.

## Model (`engine.ts`)

| Process | Rule |
|---|---|
| Lead arrival | Poisson per business day, mean 1.5 × seasonality (Dec 0.7 … Oct 1.15) × growth (+25 %/year); business hours only |
| Assignment | rep covering the city's region, weighted by capacity |
| New account | company (size-dependent 1–5 contacts, titles, tags), intro note, first task |
| Qualification | 50 % (+12 % decision maker, +10 % referral) open a deal 3–18 days later; others may get a nurture check-in |
| Deal value | log-normal around category price × company-size factor; re-scoped in negotiation, trimmed at signature |
| Pipeline | opportunity → proposal-sent → in-negotiation → won/lost, with `delayed` detours; transition odds scale with rep skill and an end-of-quarter push; stage durations follow the product's sales cycle |
| Activity | each transition writes deal notes, contact notes (status cold → warm → hot → in-contract), follow-up tasks; ~88 % of tasks are completed around their due date, the rest stay overdue |
| After close | won/lost deals are archived 10–45 days later; customers get check-ins that can open expansion deals |

## Determinism, reset and replay

The generator is seeded (mulberry32); its state and the pending event queue are stored in
`sim_state`. `reset` truncates business tables through the `sim_reset()` security-definer function
(identities restart at 1) and replays history, so the same `--seed` and `--as-of` produce a
byte-identical dataset (`hash` command; verified by tests). Every run is recorded in `sim_runs` with its hash.

```text
npm run simulate -- reset --seed 20261117 --months 13 [--as-of 2026-11-17T18:00:00Z]
npm run simulate -- advance [--until <iso>]
npm run simulate -- status | integrity | hash
```

## Live operation

With `CRM_SIMULATION=live`, the API process runs `SimulationWorker`: every `CRM_SIM_TICK_SECONDS`
(default 60) it advances the persisted simulation to the current time under a Postgres advisory
lock (one active worker). Changes are ordinary audited writes, so they reach browsers through
`NOTIFY` → SSE and dashboards refresh. `CRM_SIM_INTENSITY` (default 1 = realistic) scales lead
arrivals for demos. Records deleted by users in the meantime are skipped, not recreated.

## Integrity checks (`integrity.ts`)

21 SQL checks that must all return 0: references (deal contacts belong to the deal's company),
chronology (contact after company, deal after company, notes after their record, task done after
creation, archive after creation), closed-deal dates, valid stages and amounts, and nothing dated
after the as-of time. Plausibility tests: win rate 20–70 %, median won amount, weekend share < 2 %,
leads every month, open pipeline at as-of, work spread across the team.
