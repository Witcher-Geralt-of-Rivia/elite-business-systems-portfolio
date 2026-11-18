/**
 * Live simulation worker: every tick, advances the persisted business simulation to the current
 * time inside the API process. Changes flow through ResourceService, so they are audited and
 * reach browsers through the normal NOTIFY -> SSE path, exactly like a teammate's edits.
 * A Postgres advisory lock guarantees a single active worker even if several API processes run.
 */
import type { FastifyBaseLogger } from "fastify";
import type { Db } from "../db.ts";
import { loadSchema } from "../resources/schema.ts";
import { ResourceService } from "../resources/service.ts";
import type { TeamMember } from "./engine.ts";
import { advanceLive, ensureTeam } from "./store.ts";

const LOCK_KEY = 0x63726d73; // "crms"

export class SimulationWorker {
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private team: TeamMember[] = [];
  private service: ResourceService | null = null;
  private db: Db;
  private log: FastifyBaseLogger;
  private tickMs: number;
  private intensity: number;

  constructor(db: Db, log: FastifyBaseLogger, opts: { tickSeconds: number; intensity: number }) {
    this.db = db;
    this.log = log;
    this.tickMs = opts.tickSeconds * 1000;
    this.intensity = opts.intensity;
  }

  async start() {
    this.team = await ensureTeam(this.db);
    this.service = new ResourceService(this.db, await loadSchema(this.db));
    this.timer = setInterval(() => void this.tick(), this.tickMs);
    this.timer.unref();
    void this.tick();
  }

  async tick() {
    if (this.running || !this.service) return;
    this.running = true;
    const client = await this.db.connect();
    try {
      const { rows } = await client.query(`select pg_try_advisory_lock($1) as locked`, [LOCK_KEY]);
      if (!rows[0].locked) return;
      try {
        const result = await advanceLive(this.db, this.service, this.team, new Date(), this.intensity);
        if (!result.initialized) this.log.debug("simulation not initialized (run `npm run simulate -- reset`)");
        else if (result.handled > 0) this.log.info({ events: result.handled }, "simulation advanced");
      } finally {
        await client.query(`select pg_advisory_unlock($1)`, [LOCK_KEY]);
      }
    } catch (err) {
      this.log.error({ err }, "simulation tick failed");
    } finally {
      client.release();
      this.running = false;
    }
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
  }
}
