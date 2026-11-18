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
      return showcaseIdentity(db, user!.salesId, user!.email);
    },
  );
}

/**
 * Visitors see the CRM through the eyes of the busiest active sales rep, so the personal widgets
 * (hot contacts, upcoming tasks, "deals I manage") show a real working day instead of an empty
 * guest account. This changes only the identity returned to the UI; the session still belongs to
 * the read-only showcase account, so nothing can be written.
 */
let viewAsCache: { at: number; value: { id: number; name: string } | null } | null = null;
export async function showcaseViewAs(db: Db): Promise<{ id: number; name: string } | null> {
  if (viewAsCache && Date.now() - viewAsCache.at < 10 * 60_000) return viewAsCache.value;
  const { rows } = await db.query(
    `select s.id, s.first_name || ' ' || s.last_name as name
       from sales s
      where s.role in ('sales_rep', 'manager') and not s.disabled
      order by (select count(*) from deals d where d.sales_id = s.id and d.archived_at is null) desc, s.id
      limit 1`,
  );
  viewAsCache = { at: Date.now(), value: rows[0] ? { id: Number(rows[0].id), name: rows[0].name } : null };
  return viewAsCache.value;
}

export async function showcaseIdentity(db: Db, ownSalesId: number, email: string) {
  const viewAs = await showcaseViewAs(db);
  return {
    id: viewAs?.id ?? ownSalesId,
    fullName: viewAs ? `Guest · viewing as ${viewAs.name}` : "Guest Visitor",
    email,
    role: "showcase" as const,
    administrator: false,
  };
}
