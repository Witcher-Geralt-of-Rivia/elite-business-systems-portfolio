/**
 * Live updates: one dedicated PostgreSQL connection LISTENs on `crm_changes` (fired by the
 * notify_change() triggers from migration 0001, inside the writing transaction, so only committed
 * changes are delivered) and fans the events out to browsers over Server-Sent Events.
 *
 * GET /api/events (authenticated) -> text/event-stream of `event: change` messages
 *   data: {"table":"deals","op":"update","id":42}
 * The UI uses them to invalidate cached queries; it never trusts event payloads as data.
 */
import type { FastifyInstance, FastifyReply } from "fastify";
import pg from "pg";
import { requireUser } from "../auth/routes.ts";

const MAX_CLIENTS = 200;
const HEARTBEAT_MS = 25_000;
const STREAM_MAX_AGE_MS = 5 * 60_000;

export interface ChangeEvent {
  table: string;
  op: string;
  id: number | string;
}

export class ChangeHub {
  private clients = new Set<FastifyReply>();
  private listener: pg.Client | null = null;
  private stopped = false;
  private heartbeat: NodeJS.Timeout | null = null;
  private databaseUrl: string;
  private log: (msg: string, err?: unknown) => void;
  readonly subscribers = new Set<(e: ChangeEvent) => void>();

  constructor(databaseUrl: string, log: (msg: string, err?: unknown) => void) {
    this.databaseUrl = databaseUrl;
    this.log = log;
  }

  async start() {
    this.stopped = false;
    await this.connect();
    this.heartbeat = setInterval(() => this.write(": keep-alive\n\n"), HEARTBEAT_MS);
    this.heartbeat.unref();
  }

  private async connect(): Promise<void> {
    const client = new pg.Client({ connectionString: this.databaseUrl, application_name: "crm-events" });
    client.on("notification", (msg) => {
      if (!msg.payload) return;
      let event: ChangeEvent;
      try {
        event = JSON.parse(msg.payload);
      } catch {
        return;
      }
      for (const fn of this.subscribers) fn(event);
      this.write(`event: change\ndata: ${JSON.stringify(event)}\n\n`);
    });
    client.on("error", (err) => {
      this.log("event listener connection lost; reconnecting", err);
      this.listener = null;
      client.end().catch(() => {});
      if (!this.stopped) setTimeout(() => this.connect().catch((e) => this.log("reconnect failed", e)), 2000).unref();
    });
    await client.connect();
    await client.query("listen crm_changes");
    this.listener = client;
  }

  private write(chunk: string) {
    for (const reply of this.clients) {
      try {
        reply.raw.write(chunk);
      } catch {
        this.clients.delete(reply);
      }
    }
  }

  get clientCount() {
    return this.clients.size;
  }

  add(reply: FastifyReply): boolean {
    if (this.clients.size >= MAX_CLIENTS) return false;
    this.clients.add(reply);
    // Streams are re-authenticated by forcing a reconnect every few minutes (EventSource retries
    // automatically with the session cookie), so a revoked/disabled session stops receiving events.
    const expiry = setTimeout(() => reply.raw.end(), STREAM_MAX_AGE_MS);
    expiry.unref();
    reply.raw.on("close", () => {
      clearTimeout(expiry);
      this.clients.delete(reply);
    });
    return true;
  }

  async stop() {
    this.stopped = true;
    if (this.heartbeat) clearInterval(this.heartbeat);
    for (const reply of this.clients) reply.raw.end();
    this.clients.clear();
    await this.listener?.end().catch(() => {});
    this.listener = null;
  }
}

export function registerEventRoutes(app: FastifyInstance, hub: ChangeHub) {
  app.get("/api/events", { preHandler: requireUser, config: { rateLimit: { max: 30, timeWindow: "1 minute" } } }, async (req, reply) => {
    if (!hub.add(reply)) return reply.code(503).send({ error: "Too many live connections" });
    reply.hijack();
    reply.raw.writeHead(200, {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    });
    reply.raw.write(`retry: 5000\nevent: ready\ndata: {}\n\n`);
  });
}
