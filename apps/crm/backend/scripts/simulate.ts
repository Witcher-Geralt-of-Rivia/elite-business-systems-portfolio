/**
 * CRM data engine CLI.
 *   node --env-file=<env> scripts/simulate.ts reset [--seed 20261117] [--months 13] [--as-of 2026-11-17T12:00:00Z]
 *   node --env-file=<env> scripts/simulate.ts advance [--until <iso>]     # catch up to now (or a date)
 *   node --env-file=<env> scripts/simulate.ts status
 *   node --env-file=<env> scripts/simulate.ts hash
 *   node --env-file=<env> scripts/simulate.ts integrity                # violations (must all be 0) + business profile
 * `reset` wipes business data (companies, contacts, deals, notes, tasks, tags) and replays history
 * deterministically; team accounts, configuration and the audit log are kept.
 */
import { parseArgs } from "node:util";
import { loadConfig } from "../src/config.ts";
import { createPool } from "../src/db.ts";
import { loadSchema } from "../src/resources/schema.ts";
import { ResourceService } from "../src/resources/service.ts";
import { businessProfile, integrityViolations } from "../src/simulation/integrity.ts";
import { advanceLive, dataHash, ensureTeam, loadState, resetAndBackfill } from "../src/simulation/store.ts";

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    seed: { type: "string", default: "20261117" },
    months: { type: "string", default: "13" },
    "as-of": { type: "string" },
    until: { type: "string" },
  },
});
const command = positionals[0] ?? "status";
const config = loadConfig();
const db = createPool(config.databaseUrl, 4);

try {
  if (command === "reset") {
    const asOf = values["as-of"] ? new Date(values["as-of"]) : new Date();
    const t0 = Date.now();
    const result = await resetAndBackfill(db, {
      seed: Number(values.seed),
      months: Number(values.months),
      asOf,
      onProgress: (clock, stats) =>
        console.log(`${clock.toISOString().slice(0, 10)}  companies=${stats.companies ?? 0} deals=${(stats.deals ?? 0) + (stats.expansion_deals ?? 0)} won=${stats.stage_won ?? 0}`),
    });
    console.log(JSON.stringify({ ...result, seconds: Math.round((Date.now() - t0) / 1000) }, null, 2));
  } else if (command === "advance") {
    const team = await ensureTeam(db);
    const service = new ResourceService(db, await loadSchema(db));
    const until = values.until ? new Date(values.until) : new Date();
    console.log(JSON.stringify(await advanceLive(db, service, team, until)));
  } else if (command === "status") {
    const s = await loadState(db);
    console.log(s ? JSON.stringify({ seed: s.seed, clock: new Date(s.clock), queued: s.queue.length, stats: s.stats }, null, 2) : "not initialized");
  } else if (command === "integrity") {
    const state = await loadState(db);
    const violations = await integrityViolations(db, state ? new Date(state.clock) : undefined);
    const failing = Object.entries(violations).filter(([, n]) => n > 0);
    console.log(JSON.stringify({ checks: Object.keys(violations).length, failing, profile: await businessProfile(db) }, null, 2));
    if (failing.length) process.exitCode = 1;
  } else if (command === "hash") {
    console.log(await dataHash(db));
  } else {
    throw new Error(`Unknown command ${command}`);
  }
} finally {
  await db.end();
}
