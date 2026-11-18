/**
 * Read-only showcase access for portfolio visitors.
 *
 * - A dedicated `showcase` account WITHOUT a password (it can never sign in with credentials, and
 *   nobody can set one: password links require an authenticated, non-showcase request).
 * - POST /api/auth/showcase starts a short session for it — no credential is published anywhere.
 * - Showcase sessions are read-only at the HTTP layer: every state-changing request except logout
 *   is refused, and private attachments are not served. Resource rules (`write.showcase = none`)
 *   enforce the same thing a second time in the service layer.
 */
import type { FastifyInstance, FastifyRequest } from "fastify";
import type { AppConfig } from "../config.ts";
import type { Db } from "../db.ts";
import { audit } from "../resources/service.ts";
import { createSession, SESSION_COOKIE, resolveSession } from "./sessions.ts";

export const SHOWCASE_EMAIL = "visitor@showcase.meridian-advisory.example";
export const SHOWCASE_MESSAGE = "This is a read-only demo: changes are disabled.";
const STATE_CHANGING = new Set(["POST", "PUT", "PATCH", "DELETE"]);

/** True when a showcase session must not perform this request. */
export function showcaseForbids(req: FastifyRequest): boolean {
  const path = req.url.split("?")[0];
  if (STATE_CHANGING.has(req.method)) return path !== "/api/auth/logout";
  return path.startsWith("/api/attachments/");
}

export async function ensureShowcaseAccount(db: Db): Promise<void> {
  const u = await db.query(
    `insert into users (email, password_hash) values ($1, null)
     on conflict (email) do update set password_hash = null returning id`,
    [SHOWCASE_EMAIL],
  );
  await db.query(
    `insert into sales (first_name, last_name, email, role, user_id) values ('Guest', 'Visitor', $1, 'showcase', $2)
     on conflict (user_id) do update set role = 'showcase', disabled = false`,
    [SHOWCASE_EMAIL, u.rows[0].id],
  );
}

export function registerShowcase(app: FastifyInstance, db: Db, config: AppConfig) {
  app.post(
    "/api/auth/showcase",
    { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } },
    async (req, reply) => {
      if (!config.showcase.enabled) return reply.code(404).send({ error: "Showcase access is not enabled" });
      const { rows } = await db.query(
        `select u.id as user_id, s.id as sales_id from users u join sales s on s.user_id = u.id
          where u.email = $1 and s.role = 'showcase' and not s.disabled`,
        [SHOWCASE_EMAIL],
      );
      if (!rows[0]) return reply.code(404).send({ error: "Showcase access is not enabled" });
      const { token, expiresAt } = await createSession(db, rows[0].user_id, config.showcase.sessionHours, {
        ip: req.ip,
        userAgent: req.headers["user-agent"],
      });
      reply.setCookie(SESSION_COOKIE, token, { httpOnly: true, secure: config.cookieSecure, sameSite: "lax", path: "/", expires: expiresAt });
      await audit(db, { salesId: rows[0].sales_id, kind: "user" }, "showcase_login", "auth", null, null, req.ip);
      const user = await resolveSession(db, token);
      return { id: user!.salesId, fullName: "Guest Visitor", email: user!.email, role: "showcase", administrator: false };
    },
  );
}
