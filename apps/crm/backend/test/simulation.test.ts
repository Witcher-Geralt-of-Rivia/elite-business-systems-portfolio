/**
 * CRM data engine: determinism, integrity, business plausibility and live continuation.
 * Runs against crm_test with a 4-month window (the 13-month production run is recorded in
 * docs/TEST_RESULTS.md with the same checks).
 */
import assert from "node:assert/strict";
import { after, before, describe, test } from "node:test";
import { loadConfig } from "../src/config.ts";
import { createPool, type Db } from "../src/db.ts";
import { loadSchema } from "../src/resources/schema.ts";
import { ResourceService } from "../src/resources/service.ts";
import { catalog } from "../src/simulation/engine.ts";
import { businessProfile, integrityViolations } from "../src/simulation/integrity.ts";
import { advanceLive, dataHash, ensureTeam, loadState, resetAndBackfill } from "../src/simulation/store.ts";

const config = loadConfig();
assert.match(config.databaseUrl, /\/crm_test(\?|$)/, "tests must run against crm_test");
const AS_OF = new Date("2026-11-16T22:00:00Z");
const SEED = 4242;
let db: Db;
let first: { hash: string; stats: Record<string, number> };

before(async () => {
  db = createPool(config.databaseUrl, 4);
});
after(async () => {
  await db.end();
});

const countCuratedValues = () => {
  let n = catalog.team.length + catalog.dealCategories.length + catalog.cities.length + catalog.firstNames.length +
    catalog.lastNames.length + catalog.titles.length + catalog.companySuffixes.length + catalog.leadSources.length +
    catalog.painPoints.length + catalog.tags.length + catalog.dealNames.length + catalog.lossReasons.length +
    catalog.delayReasons.length + catalog.sizeWeights.length;
  for (const s of catalog.sectors) n += 1 + s.stems.length + s.kinds.length + s.descriptions.length;
  for (const list of Object.values(catalog.notes)) n += list.length;
  for (const list of Object.values(catalog.tasks)) n += list.length;
  return n;
};

describe("CRM data engine", () => {
  test("catalog holds roughly 500 curated, CRM-specific source values", () => {
    const n = countCuratedValues();
    assert.ok(n >= 450 && n <= 600, `curated values: ${n}`);
  });

  test("backfill produces coherent history through the API service layer", async () => {
    const result = await resetAndBackfill(db, { seed: SEED, months: 4, asOf: AS_OF });
    first = result;
    assert.ok(result.stats.companies > 60, `companies: ${result.stats.companies}`);
    assert.ok(result.stats.deals > 25, `deals: ${result.stats.deals}`);
    assert.ok((result.stats.stage_won ?? 0) > 0 && (result.stats.stage_lost ?? 0) > 0);
    // Every write was audited as the simulator, attributed to a team member
    const { rows } = await db.query(`select count(*)::int as n from audit_log where actor_kind = 'simulator' and actor_sales_id is not null`);
    assert.ok(rows[0].n > 500);
  });

  test("no integrity violations (references, chronology, nothing after the as-of date)", async () => {
    const violations = await integrityViolations(db, AS_OF);
    const failing = Object.entries(violations).filter(([, n]) => n > 0);
    assert.deepEqual(failing, []);
  });

  test("business-aware distributions", async () => {
    const p = await businessProfile(db);
    assert.ok(p.winRate > 0.2 && p.winRate < 0.7, `win rate ${p.winRate}`);
    assert.ok(p.median_won_amount >= 5000 && p.median_won_amount <= 120000, `median won ${p.median_won_amount}`);
    assert.ok(p.weekendShare < 0.02, `weekend share ${p.weekendShare}`);
    assert.ok(p.contacts >= p.companies, "every company has at least one contact");
    assert.ok(p.open_tasks > 0 && p.open_tasks < p.tasks * 0.5, "most tasks get done, some remain open");
    assert.equal(p.monthlyNewCompanies.length >= 4, true, "leads every month");
    assert.ok(p.openPipeline.some((s: any) => s.stage === "opportunity"), "pipeline still has open deals at as-of");
    const owners = new Set(p.owners.map((o: any) => o.owner));
    assert.ok(owners.size >= 4, "work is spread across the team");
    const config = await db.query(`select config -> 'dealCategories' as c from configuration where id = 1`);
    assert.equal(config.rows[0].c.length, catalog.dealCategories.length, "business categories configured for the UI");
  });

  test("deterministic: same seed and as-of replay to the identical dataset; another seed differs", async () => {
    const again = await resetAndBackfill(db, { seed: SEED, months: 4, asOf: AS_OF });
    assert.equal(again.hash, first.hash);
    assert.deepEqual(again.stats, first.stats);
    const other = await resetAndBackfill(db, { seed: SEED + 1, months: 4, asOf: AS_OF });
    assert.notEqual(other.hash, first.hash);
    // restore the reference dataset for the live test
    await resetAndBackfill(db, { seed: SEED, months: 4, asOf: AS_OF });
  });

  test("live continuation is deterministic and equals an uninterrupted run", async () => {
    const team = await ensureTeam(db);
    const service = new ResourceService(db, await loadSchema(db));
    const later = new Date(AS_OF.getTime() + 10 * 86_400_000);
    // Advance in several live ticks...
    for (let day = 1; day <= 10; day++) await advanceLive(db, service, team, new Date(AS_OF.getTime() + day * 86_400_000));
    const ticked = await dataHash(db);
    const state = await loadState(db);
    assert.equal(new Date(state!.clock).toISOString(), later.toISOString());
    assert.equal((await integrityViolations(db, later)).deal_note_before_deal, 0);
    // ...which must equal ONE uninterrupted advance over the same 10 days.
    const direct = await resetAndBackfill(db, { seed: SEED, months: 4, asOf: AS_OF });
    assert.equal(direct.hash, first.hash);
    await advanceLive(db, service, team, later);
    assert.equal(await dataHash(db), ticked);
  });

  test("live mode tolerates records deleted by users in the meantime", async () => {
    const state = await loadState(db);
    const pendingTask = state!.queue.find((e: any) => e.kind === "complete_task") as any;
    assert.ok(pendingTask, "a task completion is pending");
    await db.query(`delete from tasks where id = $1`, [pendingTask.taskId]);
    const team = await ensureTeam(db);
    const service = new ResourceService(db, await loadSchema(db));
    const result = await advanceLive(db, service, team, new Date(pendingTask.at + 1000));
    assert.equal(result.initialized, true);
  });
});
