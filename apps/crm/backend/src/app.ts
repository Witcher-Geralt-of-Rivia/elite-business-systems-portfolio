import cookie from "@fastify/cookie";
import rateLimit from "@fastify/rate-limit";
import Fastify, { type FastifyInstance } from "fastify";
import { registerAuth } from "./auth/routes.ts";
import type { AppConfig } from "./config.ts";
import type { Db } from "./db.ts";
import { registerResourceRoutes } from "./resources/routes.ts";
import { loadSchema } from "./resources/schema.ts";
import { ResourceService } from "./resources/service.ts";

const STATE_CHANGING = new Set(["POST", "PUT", "PATCH", "DELETE"]);
export const CSRF_HEADER = "x-crm-csrf";

export async function buildApp(config: AppConfig, db: Db): Promise<FastifyInstance> {
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
    return reply.code(status).send({ error: status >= 500 ? "Internal server error" : error.message });
  });

  app.get("/api/health", async () => {
    await db.query("select 1");
    return { status: "ok" };
  });

  const schema = await loadSchema(db);
  registerAuth(app, db, config);
  registerResourceRoutes(app, new ResourceService(db, schema));
  return app;
}
