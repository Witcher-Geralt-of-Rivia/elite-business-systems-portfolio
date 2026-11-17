import { createHash, randomBytes } from "node:crypto";
import type { Db } from "../db.ts";

export type Role = "admin" | "manager" | "sales_rep" | "showcase";

export interface SessionUser {
  userId: string;
  salesId: number;
  email: string;
  firstName: string;
  lastName: string;
  role: Role;
  avatar: unknown;
}

export const SESSION_COOKIE = "crm_session";

export function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export async function createSession(
  db: Db,
  userId: string,
  ttlHours: number,
  meta: { ip?: string; userAgent?: string },
): Promise<{ token: string; expiresAt: Date }> {
  const token = randomBytes(32).toString("base64url");
  const expiresAt = new Date(Date.now() + ttlHours * 3600_000);
  await db.query(
    `insert into sessions (token_hash, user_id, expires_at, ip, user_agent) values ($1, $2, $3, $4, $5)`,
    [hashToken(token), userId, expiresAt, meta.ip ?? null, meta.userAgent?.slice(0, 300) ?? null],
  );
  return { token, expiresAt };
}

/** Resolves a session token to an active, non-disabled user; slides last_seen_at. */
export async function resolveSession(db: Db, token: string | undefined): Promise<SessionUser | null> {
  if (!token || token.length > 100) return null;
  const { rows } = await db.query(
    `update sessions s set last_seen_at = now()
       from users u join sales sa on sa.user_id = u.id
      where s.token_hash = $1 and s.user_id = u.id and s.expires_at > now() and not sa.disabled
      returning u.id as user_id, sa.id as sales_id, u.email, sa.first_name, sa.last_name, sa.role, sa.avatar`,
    [hashToken(token)],
  );
  const r = rows[0];
  if (!r) return null;
  return {
    userId: r.user_id,
    salesId: r.sales_id,
    email: r.email,
    firstName: r.first_name,
    lastName: r.last_name,
    role: r.role,
    avatar: r.avatar,
  };
}

export async function revokeSession(db: Db, token: string): Promise<void> {
  await db.query(`delete from sessions where token_hash = $1`, [hashToken(token)]);
}

export async function revokeAllSessionsForUser(db: Db, userId: string): Promise<void> {
  await db.query(`delete from sessions where user_id = $1`, [userId]);
}

export async function purgeExpiredSessions(db: Db): Promise<number> {
  const { rowCount } = await db.query(`delete from sessions where expires_at < now()`);
  return rowCount ?? 0;
}
