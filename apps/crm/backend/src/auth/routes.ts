import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { AppConfig } from "../config.ts";
import type { Db } from "../db.ts";
import { audit } from "../resources/service.ts";
import { verifyPassword } from "./password.ts";
import { createSession, resolveSession, revokeSession, SESSION_COOKIE, type SessionUser } from "./sessions.ts";
import { SHOWCASE_MESSAGE, showcaseForbids } from "./showcase.ts";

const MAX_FAILED_LOGINS = 5;
const LOCK_MINUTES = 15;

declare module "fastify" {
  interface FastifyRequest {
    user: SessionUser | null;
  }
}

export function identity(u: SessionUser) {
  const avatar = u.avatar as { src?: string } | null;
  return {
    id: u.salesId,
    fullName: `${u.firstName} ${u.lastName}`,
    avatar: avatar?.src,
    email: u.email,
    role: u.role,
    administrator: u.role === "admin",
  };
}

export async function requireUser(req: FastifyRequest, reply: FastifyReply) {
  if (!req.user) return reply.code(401).send({ error: "Not authenticated" });
}

export function registerAuth(app: FastifyInstance, db: Db, config: AppConfig) {
  app.decorateRequest("user", null);

  app.addHook("onRequest", async (req, reply) => {
    req.user = await resolveSession(db, req.cookies[SESSION_COOKIE]);
    // Visitors are read-only for every route, present and future (defence in depth with the
    // per-resource rules in the service layer).
    if (req.user?.role === "showcase" && showcaseForbids(req)) {
      return reply.code(403).send({ error: SHOWCASE_MESSAGE, code: "showcase_read_only" });
    }
  });

  app.get("/api/auth/init-state", async () => {
    // The read-only visitor account does not count: the instance is initialized once a real user exists.
    const { rows } = await db.query(`select exists (select 1 from sales where role <> 'showcase') as initialized`);
    return { initialized: rows[0].initialized as boolean, showcase: config.showcase.enabled };
  });

  app.post(
    "/api/auth/login",
    {
      config: { rateLimit: { max: config.loginRateLimitPerMinute, timeWindow: "1 minute" } },
      schema: {
        body: {
          type: "object",
          required: ["email", "password"],
          additionalProperties: false,
          properties: {
            email: { type: "string", minLength: 3, maxLength: 254 },
            password: { type: "string", minLength: 1, maxLength: 256 },
          },
        },
      },
    },
    async (req, reply) => {
      const { email, password } = req.body as { email: string; password: string };
      const { rows } = await db.query(
        `select u.id, u.password_hash, u.locked_until, sa.id as sales_id, sa.disabled
           from users u left join sales sa on sa.user_id = u.id
          where u.email = $1`,
        [email.trim()],
      );
      const user = rows[0];
      const locked = user?.locked_until && new Date(user.locked_until) > new Date();
      const ok = await verifyPassword(password, user?.password_hash ?? null);
      if (!user || !ok || locked || user.disabled || !user.sales_id) {
        if (user && !locked) {
          await db.query(
            `update users set failed_login_count = failed_login_count + 1,
                    locked_until = case when failed_login_count + 1 >= $2
                                        then now() + make_interval(mins => $3) else locked_until end
              where id = $1`,
            [user.id, MAX_FAILED_LOGINS, LOCK_MINUTES],
          );
        }
        await audit(db, user?.sales_id ? { salesId: user.sales_id, kind: "user" } : null, "login_failed", "auth", null, null, req.ip);
        // Same message for every failure cause: no account enumeration.
        return reply.code(401).send({ error: "Invalid email or password." });
      }
      await db.query(`update users set failed_login_count = 0, locked_until = null, last_login_at = now() where id = $1`, [user.id]);
      const { token, expiresAt } = await createSession(db, user.id, config.sessionTtlHours, {
        ip: req.ip,
        userAgent: req.headers["user-agent"],
      });
      reply.setCookie(SESSION_COOKIE, token, {
        httpOnly: true,
        secure: config.cookieSecure,
        sameSite: "lax",
        path: "/",
        expires: expiresAt,
      });
      const sessionUser = await resolveSession(db, token);
      await audit(db, { salesId: user.sales_id, kind: "user" }, "login", "auth", null, null, req.ip);
      return identity(sessionUser!);
    },
  );

  app.post("/api/auth/logout", async (req, reply) => {
    const token = req.cookies[SESSION_COOKIE];
    if (token) await revokeSession(db, token);
    if (req.user) await audit(db, { salesId: req.user.salesId, kind: "user" }, "logout", "auth", null, null, req.ip);
    reply.clearCookie(SESSION_COOKIE, { path: "/" });
    return { ok: true };
  });

  app.get("/api/auth/me", { preHandler: requireUser }, async (req) => identity(req.user!));
}
