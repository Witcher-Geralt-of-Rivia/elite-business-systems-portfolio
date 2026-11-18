/**
 * Contact merge (replaces upstream's `merge_contacts` edge function / commons/mergeContacts.ts).
 * Same field rules as upstream, but executed as ONE transaction: tasks, notes and deal links move
 * to the winner, the winner absorbs the loser's emails/phones/tags/missing fields, the loser is
 * deleted. Either everything happens or nothing does.
 */
import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth/routes.ts";
import { withTransaction, type Db } from "../db.ts";
import { RESOURCES } from "../resources/registry.ts";
import { audit, publicRow, type Actor } from "../resources/service.ts";
import { BadRequest, Forbidden, NotFound } from "../resources/schema.ts";

type Row = Record<string, any>;

function uniqueBy<T>(items: T[], key: (t: T) => unknown): T[] {
  const seen = new Set<unknown>();
  return items.filter((item) => {
    const k = key(item);
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

/** Field rules mirror upstream mergeContacts(): winner wins, loser fills gaps, lists are unioned. */
export function mergedFields(winner: Row, loser: Row): Row {
  const pick = (k: string) => winner[k] ?? loser[k];
  return {
    avatar: winner.avatar?.src ? winner.avatar : loser.avatar,
    gender: pick("gender"),
    first_name: pick("first_name"),
    last_name: pick("last_name"),
    title: pick("title"),
    company_id: pick("company_id"),
    email_jsonb: uniqueBy([...(winner.email_jsonb ?? []), ...(loser.email_jsonb ?? [])], (e: Row) => e.email),
    phone_jsonb: uniqueBy([...(winner.phone_jsonb ?? []), ...(loser.phone_jsonb ?? [])], (p: Row) => p.number),
    linkedin_url: winner.linkedin_url || loser.linkedin_url,
    background: pick("background"),
    has_newsletter: pick("has_newsletter"),
    first_seen: [winner.first_seen, loser.first_seen].filter(Boolean).sort((a, b) => +new Date(a) - +new Date(b))[0] ?? null,
    last_seen: [winner.last_seen, loser.last_seen].filter(Boolean).sort((a, b) => +new Date(b) - +new Date(a))[0] ?? null,
    sales_id: pick("sales_id"),
    tags: [...new Set([...(winner.tags ?? []), ...(loser.tags ?? [])])],
  };
}

export async function mergeContacts(db: Db, actor: Actor, loserId: number, winnerId: number, ip?: string) {
  if (loserId === winnerId) throw new BadRequest("Cannot merge a contact into itself.");
  const access = RESOURCES.contacts.write[actor.role];
  if (access === "none") throw new Forbidden("Your role cannot modify contacts.");
  return withTransaction(db, async (c) => {
    // Lock in id order to avoid deadlocks between concurrent merges.
    const { rows } = await c.query(`select * from contacts where id = any($1::bigint[]) order by id for update`, [[loserId, winnerId]]);
    const winner = rows.find((r) => Number(r.id) === winnerId);
    const loser = rows.find((r) => Number(r.id) === loserId);
    if (!winner || !loser) throw new NotFound("Contact not found");
    if (access === "own" && (winner.sales_id !== actor.salesId || loser.sales_id !== actor.salesId)) {
      throw new Forbidden("You can only merge contacts you own.");
    }

    const tasks = await c.query(`update tasks set contact_id = $2 where contact_id = $1`, [loserId, winnerId]);
    const notes = await c.query(`update contact_notes set contact_id = $2 where contact_id = $1`, [loserId, winnerId]);
    // Replace the loser by the winner in deals.contact_ids, keeping order and removing duplicates.
    const deals = await c.query(
      `update deals d set contact_ids = (
           select array_agg(x order by first_pos) from (
             select x, min(pos) as first_pos
               from unnest(array_replace(d.contact_ids, $1::bigint, $2::bigint)) with ordinality as u(x, pos)
              group by x) s)
        where $1::bigint = any(d.contact_ids)`,
      [loserId, winnerId],
    );

    const fields = mergedFields(winner, loser);
    const keys = Object.keys(fields);
    const values = keys.map((k) =>
      k === "email_jsonb" || k === "phone_jsonb" || k === "avatar" ? (fields[k] == null ? null : JSON.stringify(fields[k])) : fields[k],
    );
    await c.query(
      `update contacts set ${keys.map((k, i) => `${k} = $${i + 2}`).join(", ")} where id = $1`,
      [winnerId, ...values],
    );
    await c.query(`delete from contacts where id = $1`, [loserId]);
    await audit(c, actor, "merge", "contacts", winnerId, {
      loser_id: loserId,
      moved: { tasks: tasks.rowCount, contact_notes: notes.rowCount, deals: deals.rowCount },
    }, ip);
    const merged = await c.query(`select * from contacts_summary where id = $1`, [winnerId]);
    return publicRow(merged.rows[0]);
  });
}

export function registerMergeRoutes(app: FastifyInstance, db: Db) {
  app.post(
    "/api/contacts/:id/merge",
    {
      preHandler: requireUser,
      schema: {
        params: { type: "object", properties: { id: { type: "string", pattern: "^[0-9]{1,18}$" } } },
        body: { type: "object", required: ["winnerId"], properties: { winnerId: { type: "integer", minimum: 1 } } },
      },
    },
    async (req) => {
      const loserId = Number((req.params as { id: string }).id);
      const { winnerId } = req.body as { winnerId: number };
      return { data: await mergeContacts(db, req.user!, loserId, winnerId, req.ip) };
    },
  );
}
