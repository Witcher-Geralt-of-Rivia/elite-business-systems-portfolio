/**
 * Persistence for the CRM data engine. All business writes go through ResourceService (the same
 * validation, constraints and audit trail as user edits) with a `simulator` actor that may set
 * historical created_at / updated_at.
 */
import { createHash } from "node:crypto";
import type { Db } from "../db.ts";
import type { Role } from "../auth/sessions.ts";
import { loadSchema, NotFound } from "../resources/schema.ts";
import { ResourceService, type Actor } from "../resources/service.ts";
import { catalog, Engine, initialState, type EngineState, type TeamMember, type Writer } from "./engine.ts";

const ascii = (s: string) => s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();

/** Ensures the synthetic sales team exists (accounts without a password: they cannot sign in). */
export async function ensureTeam(db: Db): Promise<TeamMember[]> {
  const team: TeamMember[] = [];
  for (const m of catalog.team) {
    if (m.role === "admin") continue; // the real administrator account is never simulated
    const email = `${ascii(m.first_name)}.${ascii(m.last_name)}@${catalog.business.domain}`;
    let { rows } = await db.query(`select id from sales where email = $1`, [email]);
    if (!rows[0]) {
      const u = await db.query(`insert into users (email) values ($1) on conflict (email) do update set email = excluded.email returning id`, [email]);
      rows = (
        await db.query(
          `insert into sales (first_name, last_name, email, role, user_id) values ($1, $2, $3, $4, $5) returning id`,
          [m.first_name, m.last_name, email, m.role as Role, u.rows[0].id],
        )
      ).rows;
    }
    team.push({ salesId: rows[0].id, skill: m.skill, capacity: m.capacity, regions: m.regions });
  }
  return team;
}

/** Sets the business-specific deal categories and currency (keeps any other settings). */
export async function ensureConfiguration(db: Db) {
  const categories = catalog.dealCategories.map(({ value, label }) => ({ value, label }));
  await db.query(
    `insert into configuration (id, config) values (1, $1::jsonb)
     on conflict (id) do update set config = configuration.config || $1::jsonb`,
    [JSON.stringify({ dealCategories: categories, currency: catalog.business.currency })],
  );
}

export function serviceWriter(db: Db, service: ResourceService, opts: { tolerateMissing: boolean }): Writer {
  const actor = (salesId: number): Actor => ({
    userId: "simulator",
    salesId,
    email: "simulator@localhost",
    firstName: "Simulation",
    lastName: "Engine",
    role: "admin",
    avatar: null,
    kind: "simulator",
  });
  return {
    async create(resource, ownerId, data) {
      const row = await service.create(resource, actor(ownerId), data);
      return Number(row.id);
    },
    async update(resource, ownerId, id, data) {
      try {
        await service.update(resource, actor(ownerId), id, data);
      } catch (error) {
        // Live mode: a user may have deleted the record in the meantime — the business event lapses.
        if (opts.tolerateMissing && error instanceof NotFound) return;
        throw error;
      }
    },
  };
}

export async function loadState(db: Db): Promise<EngineState | null> {
  const { rows } = await db.query(`select * from sim_state where id = 1`);
  const r = rows[0];
  if (!r) return null;
  return {
    seed: Number(r.seed),
    scenarioStart: new Date(r.scenario_start).getTime(),
    clock: new Date(r.clock).getTime(),
    rngState: Number(r.rng_state),
    seq: r.stats.seq ?? 0,
    queue: r.queue,
    usedNames: r.stats.usedNames ?? [],
    dealIndex: r.stats.dealIndex ?? 0,
    tagIds: r.stats.tagIds ?? {},
    stats: r.stats.counters ?? {},
  };
}

export async function saveState(db: Db, s: EngineState, tickIncrement = 0) {
  const stats = { seq: s.seq, usedNames: s.usedNames, dealIndex: s.dealIndex, tagIds: s.tagIds, counters: s.stats };
  await db.query(
    `insert into sim_state (id, seed, scenario_start, clock, tick, rng_state, queue, stats, updated_at)
     values (1, $1, $2, $3, $4, $5, $6, $7, now())
     on conflict (id) do update set clock = $3, tick = sim_state.tick + $4, rng_state = $5, queue = $6, stats = $7, updated_at = now()`,
    [s.seed, new Date(s.scenarioStart), new Date(s.clock), tickIncrement, s.rngState, JSON.stringify(s.queue), JSON.stringify(stats)],
  );
}

/**
 * Canonical fingerprint of the business data (all rows, ordered, every column that the engine
 * controls). Two replays with the same seed / start / as-of must produce the same hash.
 */
export async function dataHash(db: Db): Promise<string> {
  const h = createHash("sha256");
  const tables: [string, string][] = [
    ["companies", "id, name, sector, size, revenue, website, phone_number, address, zipcode, city, state_abbr, sales_id, created_at, description"],
    ["contacts", "id, first_name, last_name, gender, title, company_id, email_jsonb, phone_jsonb, first_seen, last_seen, status, tags, sales_id"],
    ["deals", "id, name, company_id, contact_ids, categories, stage, amount, created_at, updated_at, archived_at, expected_closing_date, sales_id, index"],
    ["contact_notes", "id, contact_id, text, date, status, sales_id"],
    ["deal_notes", "id, deal_id, type, text, date, sales_id"],
    ["tasks", "id, contact_id, type, text, due_date, done_date, created_at, sales_id"],
    ["tags", "id, name, color"],
  ];
  for (const [table, cols] of tables) {
    const { rows } = await db.query(`select ${cols} from ${table} order by id`);
    h.update(table);
    for (const row of rows) h.update(JSON.stringify(row));
  }
  return h.digest("hex");
}

export interface ResetOptions {
  seed: number;
  months: number;
  asOf: Date;
  onProgress?: (clock: Date, stats: Record<string, number>) => void;
}

/** Deterministic reset: wipe business data, then replay `months` of history up to `asOf`. */
export async function resetAndBackfill(db: Db, opts: ResetOptions) {
  const start = new Date(opts.asOf);
  start.setUTCMonth(start.getUTCMonth() - opts.months);
  await db.query(`select sim_reset()`);
  const run = await db.query(`insert into sim_runs (seed, scenario_start, as_of) values ($1, $2, $3) returning id`, [opts.seed, start, opts.asOf]);
  const team = await ensureTeam(db);
  await ensureConfiguration(db);
  const service = new ResourceService(db, await loadSchema(db));
  const engine = new Engine(initialState(opts.seed, start), serviceWriter(db, service, { tolerateMissing: false }), team);

  // Advance month by month so progress can be reported; the result is identical to one big step.
  let cursor = engine.state.clock;
  const target = opts.asOf.getTime();
  while (cursor < target) {
    cursor = Math.min(target, cursor + 30 * 86_400_000);
    await engine.advanceTo(cursor);
    opts.onProgress?.(new Date(engine.state.clock), engine.state.stats);
  }
  await saveState(db, engine.state);
  const hash = await dataHash(db);
  await db.query(`update sim_runs set finished_at = now(), stats = $2, data_hash = $3 where id = $1`, [run.rows[0].id, JSON.stringify(engine.state.stats), hash]);
  return { stats: engine.state.stats, hash, scenarioStart: start };
}

/** Live mode: advance the persisted simulation to `now`, saving state after every event. */
export async function advanceLive(db: Db, service: ResourceService, team: TeamMember[], now: Date, intensity = 1) {
  const state = await loadState(db);
  if (!state) return { handled: 0, initialized: false };
  const engine = new Engine(state, serviceWriter(db, service, { tolerateMissing: true }), team);
  engine.intensity = intensity;
  const handled = await engine.advanceTo(now.getTime(), () => saveState(db, engine.state));
  await saveState(db, engine.state, 1);
  return { handled, initialized: true };
}
