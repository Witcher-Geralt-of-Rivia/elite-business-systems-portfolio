import cookie from "@fastify/cookie";
import rateLimit from "@fastify/rate-limit";
import Fastify, { type FastifyInstance } from "fastify";
import { registerAuth } from "./auth/routes.ts";
import type { AppConfig } from "./config.ts";
import { registerAttachmentRoutes } from "./attachments/routes.ts";
import { registerConfigurationRoutes } from "./configuration/routes.ts";
import { registerMergeRoutes } from "./contacts/merge.ts";
import { ChangeHub, registerEventRoutes } from "./realtime/events.ts";
import { registerSearchRoutes } from "./search/routes.ts";
import { registerUserRoutes } from "./users/routes.ts";
import type { Db } from "./db.ts";
import { registerResourceRoutes } from "./resources/routes.ts";
import { loadSchema } from "./resources/schema.ts";
import { ResourceService } from "./resources/service.ts";

const STATE_CHANGING = new Set(["POST", "PUT", "PATCH", "DELETE"]);
export const CSRF_HEADER = "x-crm-csrf";

export interface AppOptions {
  /** Live-update hub; created (and closed with the app) when not supplied. */
  hub?: ChangeHub;
}

export async function buildApp(config: AppConfig, db: Db, options: AppOptions = {}): Promise<FastifyInstance> {
  const app = Fastify({
    logger: { level: config.logLevel, redact: ["req.headers.cookie", "req.body.password"] },
    trustProxy: "127.0.0.1", // only Caddy on loopback may set X-Forwarded-*
    bodyLimit: 1_048_576,
  });

  await app.register(cookie);
  await app.register(rateLimit, { global: true, max: 300, timeWindow: "1 minute" });

  // CSRF defence for cookie auth: state-changing requests must (1) come from our own origin and
  // (2) carry a custom header, which cross-site forms cannot set without a CORS preflight we never grant.
  app.addHook("onRequest", async (req, reply) => {
    if (!STATE_CHANGING.has(req.method)) return;
    const origin = req.headers.origin;
    if (origin && origin !== config.publicOrigin) return reply.code(403).send({ error: "Cross-origin request refused" });
    if (req.headers[CSRF_HEADER] !== "1") return reply.code(403).send({ error: "Missing CSRF header" });
  });

  app.addHook("onSend", async (_req, reply) => {
    reply.header("Cache-Control", "no-store");
    reply.header("X-Content-Type-Options", "nosniff");
  });

  app.setErrorHandler((error: Error & { statusCode?: number; validation?: unknown }, req, reply) => {
    const status = error.statusCode ?? 500;
    if (status >= 500) req.log.error({ err: error }, "request failed");
    // Postgres constraint violations -> 400 with a safe message
    const pgCode = (error as { code?: string }).code;
    if (pgCode && /^(23|22)/.test(pgCode)) return reply.code(400).send({ error: "Invalid data", code: pgCode });
    if (status >= 500) return reply.code(status).send({ error: "Internal server error" });
    // Domain errors may carry a machine-readable code (e.g. email_taken + email for the team UI).
    const extra = error as { code?: unknown; email?: unknown };
    const body: Record<string, unknown> = { error: error.message };
    if (typeof extra.code === "string" && !extra.code.startsWith("FST_")) body.code = extra.code;
    if (typeof extra.email === "string") body.email = extra.email;
    return reply.code(status).send(body);
  });

  app.get("/api/health", async () => {
    await db.query("select 1");
    return { status: "ok" };
  });

  const schema = await loadSchema(db);
  registerAuth(app, db, config);
  registerResourceRoutes(app, new ResourceService(db, schema));
  registerConfigurationRoutes(app, db);
  registerSearchRoutes(app, db);
  registerUserRoutes(app, db, config);
  registerMergeRoutes(app, db);
  registerAttachmentRoutes(app, db, config.attachmentsDir);

  const hub = options.hub ?? new ChangeHub(config.databaseUrl, (msg, err) => app.log.warn({ err }, msg));
  if (!options.hub) {
    await hub.start();
    app.addHook("onClose", async () => hub.stop());
  }
  registerEventRoutes(app, hub);
  return app;
}
