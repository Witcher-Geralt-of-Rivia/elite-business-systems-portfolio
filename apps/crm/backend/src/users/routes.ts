/**
 * Team management, invitations and password management (replaces upstream's `users` and
 * `update_password` edge functions and Supabase Auth sign-up / recovery).
 *
 * No email service is configured (zero-cost hosting), so one-time links are returned to the
 * caller instead of being mailed: an admin hands an invitation/reset link to the team member
 * through their own channel. Tokens are random 256-bit values; only sha256(token) is stored.
 */
import { randomBytes } from "node:crypto";
import type { FastifyInstance } from "fastify";
import type { AppConfig } from "../config.ts";
import { withTransaction, type Db, type DbClient } from "../db.ts";
import { hashPassword, validatePasswordStrength } from "../auth/password.ts";
import { requireUser } from "../auth/routes.ts";
import { hashToken, revokeAllSessionsForUser, type Role, type SessionUser } from "../auth/sessions.ts";
import { audit } from "../resources/service.ts";
import { BadRequest, Forbidden, NotFound } from "../resources/schema.ts";

const INVITE_TTL_HOURS = 72;
const RESET_TTL_HOURS = 1;
const ROLES: Role[] = ["admin", "manager", "sales_rep", "showcase"];
const EMAIL = { type: "string", minLength: 3, maxLength: 254, pattern: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$" } as const;
const NAME = { type: "string", minLength: 1, maxLength: 100 } as const;

class Conflict extends Error {
  statusCode = 409;
  code: string;
  email: string;
  constructor(email: string) {
    super(`Email already used by another user: ${email}`);
    this.code = "email_taken";
    this.email = email;
  }
}

const saleColumns = `id, first_name, last_name, email, role, administrator, avatar, disabled, secondary_emails, user_id`;

function normalizeEmails(list: unknown): string[] {
  if (list == null) return [];
  if (!Array.isArray(list)) throw new BadRequest("secondary_emails must be an array");
  const out = [...new Set(list.map((e) => String(e).trim().toLowerCase()).filter(Boolean))];
  if (out.length > 10) throw new BadRequest("At most 10 secondary emails");
  for (const e of out) if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)) throw new BadRequest(`Invalid email: ${e}`);
  return out;
}

/** An address may belong to one team member only, as primary or secondary email. */
async function assertEmailsFree(c: DbClient, emails: string[], excludeSalesId?: number) {
  for (const email of emails) {
    const { rows } = await c.query(
      `select 1 from sales
        where (email = $1 or secondary_emails @> jsonb_build_array($1::text)) and id is distinct from $2
       union all
       select 1 from users u where u.email = $1
          and not exists (select 1 from sales s where s.user_id = u.id and s.id = $2)
       limit 1`,
      [email, excludeSalesId ?? null],
    );
    if (rows.length) throw new Conflict(email);
  }
}

async function issueToken(c: DbClient | Db, userId: string, purpose: "invite" | "reset", createdBy: number | null) {
  const token = randomBytes(32).toString("base64url");
  const ttl = purpose === "invite" ? INVITE_TTL_HOURS : RESET_TTL_HOURS;
  const expiresAt = new Date(Date.now() + ttl * 3600_000);
  // Only the newest link is valid.
  await c.query(`update password_reset_tokens set used_at = now() where user_id = $1 and used_at is null`, [userId]);
  await c.query(
    `insert into password_reset_tokens (token_hash, user_id, expires_at, purpose, created_by) values ($1, $2, $3, $4, $5)`,
    [hashToken(token), userId, expiresAt, purpose, createdBy],
  );
  return { token, expiresAt };
}

export function passwordLink(config: AppConfig, token: string) {
  return `${config.publicOrigin}/#/set-password?token=${encodeURIComponent(token)}`;
}

async function countActiveAdmins(c: DbClient, excludeSalesId?: number) {
  const { rows } = await c.query(
    `select count(*)::int as n from sales where role = 'admin' and not disabled and id is distinct from $1`,
    [excludeSalesId ?? null],
  );
  return rows[0].n as number;
}

function requireAdmin(user: SessionUser) {
  if (user.role !== "admin") throw new Forbidden("Only administrators can manage the team.");
}

function roleFrom(body: { role?: string; administrator?: boolean }, current?: Role): Role | undefined {
  if (body.role !== undefined) {
    if (!ROLES.includes(body.role as Role)) throw new BadRequest("Invalid role");
    return body.role as Role;
  }
  // The upstream UI only has an "administrator" switch: map it onto the role model.
  if (body.administrator === true) return "admin";
  if (body.administrator === false) return current === "admin" || current === undefined ? "sales_rep" : current;
  return undefined;
}

export function registerUserRoutes(app: FastifyInstance, db: Db, config: AppConfig) {
  // ---------------------------------------------------------------- first-run sign-up
  app.post(
    "/api/auth/signup",
    {
      config: { rateLimit: { max: 5, timeWindow: "1 minute" } },
      schema: {
        body: {
          type: "object",
          required: ["email", "password", "first_name", "last_name"],
          additionalProperties: false,
          properties: { email: EMAIL, password: { type: "string", maxLength: 256 }, first_name: NAME, last_name: NAME },
        },
      },
    },
    async (req, reply) => {
      const body = req.body as { email: string; password: string; first_name: string; last_name: string };
      const weak = validatePasswordStrength(body.password);
      if (weak) throw new BadRequest(weak);
      const hash = await hashPassword(body.password);
      const created = await withTransaction(db, async (c) => {
        // Serialise concurrent first-run attempts; only an empty instance accepts a sign-up.
        await c.query(`select pg_advisory_xact_lock(hashtext('crm_first_signup'))`);
        const { rows } = await c.query(`select count(*)::int as n from users`);
        if (rows[0].n > 0) return null;
        const email = body.email.trim().toLowerCase();
        const u = await c.query(`insert into users (email, password_hash) values ($1, $2) returning id`, [email, hash]);
        const s = await c.query(
          `insert into sales (first_name, last_name, email, role, user_id) values ($1, $2, $3, 'admin', $4) returning id`,
          [body.first_name, body.last_name, email, u.rows[0].id],
        );
        await audit(c, { salesId: s.rows[0].id, kind: "user" }, "signup", "auth", s.rows[0].id, null, req.ip);
        return { id: u.rows[0].id as string, email };
      });
      if (!created) return reply.code(403).send({ error: "This CRM is already initialized. Ask an administrator for an invitation." });
      return reply.code(201).send(created);
    },
  );

  // ---------------------------------------------------------------- set password from a one-time link
  app.post(
    "/api/auth/set-password",
    {
      config: { rateLimit: { max: 10, timeWindow: "1 minute" } },
      schema: {
        body: {
          type: "object",
          required: ["token", "password"],
          additionalProperties: false,
          properties: { token: { type: "string", minLength: 20, maxLength: 100 }, password: { type: "string", maxLength: 256 } },
        },
      },
    },
    async (req, reply) => {
      const { token, password } = req.body as { token: string; password: string };
      const weak = validatePasswordStrength(password);
      if (weak) throw new BadRequest(weak);
      const hash = await hashPassword(password);
      const result = await withTransaction(db, async (c) => {
        const { rows } = await c.query(
          `update password_reset_tokens t set used_at = now()
             from users u
            where t.token_hash = $1 and t.user_id = u.id and t.used_at is null and t.expires_at > now()
            returning t.user_id, t.purpose, u.email`,
          [hashToken(token)],
        );
        const row = rows[0];
        if (!row) return null;
        await c.query(
          `update users set password_hash = $2, failed_login_count = 0, locked_until = null where id = $1`,
          [row.user_id, hash],
        );
        await c.query(`delete from sessions where user_id = $1`, [row.user_id]);
        const s = await c.query(`select id from sales where user_id = $1`, [row.user_id]);
        await audit(c, s.rows[0] ? { salesId: s.rows[0].id, kind: "user" } : null, `password_set_${row.purpose}`, "auth", null, null, req.ip);
        return { email: row.email as string };
      });
      if (!result) return reply.code(400).send({ error: "This link is invalid or has expired. Ask an administrator for a new one." });
      return result;
    },
  );

  // ---------------------------------------------------------------- authenticated team management
  app.register(async (r) => {
    r.addHook("preHandler", requireUser);

    // Invite a team member: creates the account without a password and returns a one-time link.
    r.post(
      "/api/users",
      {
        schema: {
          body: {
            type: "object",
            required: ["email", "first_name", "last_name"],
            properties: {
              email: EMAIL,
              first_name: NAME,
              last_name: NAME,
              administrator: { type: "boolean" },
              role: { type: "string" },
              disabled: { type: "boolean" },
              secondary_emails: { type: "array", items: { type: "string" } },
              avatar: {},
              password: {}, // sent by the upstream form; ignored: the invitee chooses their own password
            },
          },
        },
      },
      async (req, reply) => {
        requireAdmin(req.user!);
        const body = req.body as Record<string, any>;
        const email = String(body.email).trim().toLowerCase();
        const secondary = normalizeEmails(body.secondary_emails).filter((e) => e !== email);
        const role = roleFrom(body) ?? "sales_rep";
        const out = await withTransaction(db, async (c) => {
          await assertEmailsFree(c, [email, ...secondary]);
          const u = await c.query(`insert into users (email) values ($1) returning id`, [email]);
          const { rows } = await c.query(
            `insert into sales (first_name, last_name, email, role, user_id, disabled, secondary_emails, avatar)
             values ($1, $2, $3, $4, $5, $6, $7, $8) returning ${saleColumns}`,
            [body.first_name, body.last_name, email, role, u.rows[0].id, body.disabled ?? false,
             JSON.stringify(secondary), body.avatar == null ? null : JSON.stringify(body.avatar)],
          );
          const link = await issueToken(c, u.rows[0].id, "invite", req.user!.salesId);
          await audit(c, req.user, "invite", "sales", rows[0].id, { email, role }, req.ip);
          return { sale: rows[0], link };
        });
        return reply.code(201).send({
          data: out.sale,
          invitation: { url: passwordLink(config, out.link.token), expiresAt: out.link.expiresAt },
        });
      },
    );

    // Update a team member. Admins: everything. Others: their own name, emails and avatar.
    r.patch(
      "/api/users/:id",
      {
        schema: {
          params: { type: "object", properties: { id: { type: "string", pattern: "^[0-9]{1,18}$" } } },
          body: {
            type: "object",
            properties: {
              email: EMAIL,
              first_name: NAME,
              last_name: NAME,
              administrator: { type: "boolean" },
              role: { type: "string" },
              disabled: { type: "boolean" },
              secondary_emails: { type: "array", items: { type: "string" } },
              avatar: {},
              sales_id: {},
            },
          },
        },
      },
      async (req) => {
        const salesId = Number((req.params as { id: string }).id);
        const actor = req.user!;
        const isSelf = actor.salesId === salesId;
        const body = req.body as Record<string, any>;
        if (!isSelf) requireAdmin(actor);
        const sale = await withTransaction(db, async (c) => {
          const cur = (await c.query(`select ${saleColumns} from sales where id = $1 for update`, [salesId])).rows[0];
          if (!cur) throw new NotFound("Team member not found");
          const changes: Record<string, unknown> = {};
          const email = body.email !== undefined ? String(body.email).trim().toLowerCase() : undefined;
          const secondary = body.secondary_emails !== undefined ? normalizeEmails(body.secondary_emails) : undefined;
          const role = roleFrom(body, cur.role);
          const disabled = body.disabled;

          if (actor.role !== "admin" && ((role && role !== cur.role) || (disabled !== undefined && disabled !== cur.disabled))) {
            throw new Forbidden("Only administrators can change roles or disable accounts.");
          }
          const losesAdmin = cur.role === "admin" && ((role && role !== "admin") || disabled === true);
          if (losesAdmin && (await countActiveAdmins(c, salesId)) === 0) {
            throw new BadRequest("At least one active administrator must remain.");
          }
          const newEmails = [email && email !== cur.email ? email : null, ...(secondary ?? [])].filter(Boolean) as string[];
          if (newEmails.length) await assertEmailsFree(c, newEmails, salesId);

          if (body.first_name !== undefined && body.first_name !== cur.first_name) changes.first_name = body.first_name;
          if (body.last_name !== undefined && body.last_name !== cur.last_name) changes.last_name = body.last_name;
          if (email && email !== cur.email) changes.email = email;
          if (secondary) changes.secondary_emails = JSON.stringify(secondary.filter((e) => e !== (email ?? cur.email)));
          if (role && role !== cur.role) changes.role = role;
          if (disabled !== undefined && disabled !== cur.disabled) changes.disabled = disabled;
          if (body.avatar !== undefined) changes.avatar = body.avatar == null ? null : JSON.stringify(body.avatar);

          const keys = Object.keys(changes);
          if (keys.length) {
            const sets = keys.map((k, i) => `${k} = $${i + 2}`).join(", ");
            await c.query(`update sales set ${sets} where id = $1`, [salesId, ...keys.map((k) => changes[k])]);
            if (changes.email) await c.query(`update users set email = $2 where id = $1`, [cur.user_id, changes.email]);
            await audit(c, actor, "update", "sales", salesId, { ...changes, avatar: undefined }, req.ip);
          }
          // Disabling or demoting ends existing sessions so the change applies immediately.
          if (changes.disabled === true || changes.role) await c.query(`delete from sessions where user_id = $1`, [cur.user_id]);
          return (await c.query(`select ${saleColumns} from sales where id = $1`, [salesId])).rows[0];
        });
        return { data: sale };
      },
    );

    // One-time password link: admins for anyone, everyone for themselves.
    r.post(
      "/api/users/:id/password-link",
      { schema: { params: { type: "object", properties: { id: { type: "string", pattern: "^[0-9]{1,18}$" } } } } },
      async (req) => {
        const salesId = Number((req.params as { id: string }).id);
        const actor = req.user!;
        if (actor.salesId !== salesId) requireAdmin(actor);
        const { rows } = await db.query(`select user_id, password_hash is null as pending
                                           from sales s join users u on u.id = s.user_id where s.id = $1`, [salesId]);
        if (!rows[0]) throw new NotFound("Team member not found");
        const purpose = rows[0].pending ? "invite" : "reset";
        const link = await withTransaction(db, async (c) => {
          const l = await issueToken(c, rows[0].user_id, purpose, actor.salesId);
          await audit(c, actor, `password_link_${purpose}`, "sales", salesId, null, req.ip);
          return l;
        });
        return { url: passwordLink(config, link.token), expiresAt: link.expiresAt, purpose };
      },
    );

    // Revoke every session of a team member (admin) — e.g. after a lost device.
    r.post(
      "/api/users/:id/revoke-sessions",
      { schema: { params: { type: "object", properties: { id: { type: "string", pattern: "^[0-9]{1,18}$" } } } } },
      async (req) => {
        requireAdmin(req.user!);
        const salesId = Number((req.params as { id: string }).id);
        const { rows } = await db.query(`select user_id from sales where id = $1`, [salesId]);
        if (!rows[0]) throw new NotFound("Team member not found");
        await revokeAllSessionsForUser(db, rows[0].user_id);
        await audit(db, req.user, "revoke_sessions", "sales", salesId, null, req.ip);
        return { ok: true };
      },
    );
  });
}
