import type { SessionUser } from "../auth/sessions.ts";
import { withTransaction, type Db, type DbClient } from "../db.ts";
import { buildOrderBy, buildWhere, SqlParams } from "./filters.ts";
import { ALWAYS_PROTECTED, RESOURCES, type ResourceDef } from "./registry.ts";
import { BadRequest, Forbidden, NotFound, quoteIdent, toDbValue, type SchemaInfo } from "./schema.ts";

export interface ListQuery {
  filter: Record<string, unknown>;
  sort?: string;
  order?: string;
  start: number;
  end: number;
}

export type Actor = SessionUser & { kind?: "user" | "simulator" };

const MAX_PAGE = 1000;

/** Internal columns never returned to clients (search vectors are an index detail). */
const HIDDEN_COLUMNS = ["fts"];
export function publicRow<T extends Record<string, unknown> | undefined>(row: T): T {
  if (!row) return row;
  for (const c of HIDDEN_COLUMNS) delete (row as Record<string, unknown>)[c];
  return row;
}

export class ResourceService {
  private db: Db;
  private schema: SchemaInfo;

  constructor(db: Db, schema: SchemaInfo) {
    this.db = db;
    this.schema = schema;
  }

  private def(resource: string): ResourceDef {
    const def = RESOURCES[resource];
    if (!def) throw new NotFound(`Unknown resource: ${resource}`);
    return def;
  }

  private cols(relation: string) {
    const cols = this.schema.get(relation);
    if (!cols) throw new Error(`Relation ${relation} missing from schema`);
    return cols;
  }

  async list(resource: string, q: ListQuery) {
    const def = this.def(resource);
    const cols = this.cols(def.readRelation);
    const p = new SqlParams();
    const where = buildWhere(q.filter, cols, p, def.searchColumns);
    const whereSql = where.length ? `where ${where.join(" and ")}` : "";
    const limit = Math.min(Math.max(q.end - q.start, 0), MAX_PAGE);
    const rel = quoteIdent(def.readRelation);
    const countValues = [...p.values];
    const sql = `select * from ${rel} ${whereSql} ${buildOrderBy(q.sort, q.order, cols)}
                 limit ${p.add(limit)} offset ${p.add(Math.max(q.start, 0))}`;
    const [data, count] = await Promise.all([
      this.db.query(sql, p.values),
      this.db.query(`select count(*)::int as total from ${rel} ${whereSql}`, countValues),
    ]);
    return { data: data.rows.map(publicRow), total: count.rows[0].total as number };
  }

  async getOne(resource: string, id: string | number) {
    const def = this.def(resource);
    const { rows } = await this.db.query(`select * from ${quoteIdent(def.readRelation)} where id = $1`, [id]);
    if (!rows[0]) throw new NotFound(`${resource} ${id} not found`);
    return publicRow(rows[0]);
  }

  private writableData(def: ResourceDef, actor: Actor, data: Record<string, unknown>) {
    const cols = this.cols(def.table);
    const blocked = new Set<string>([...ALWAYS_PROTECTED, ...(def.protectedColumns ?? [])]);
    // Backdated history is written by the simulator through this same service.
    if (actor.kind === "simulator") blocked.delete("created_at");
    const out: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(data)) {
      const col = cols.get(key);
      // Unknown keys (e.g. computed view columns echoed back by the UI) are ignored, not stored.
      if (!col || blocked.has(key) || col.isGenerated || col.isIdentityAlways) continue;
      out[key] = toDbValue(col, value);
    }
    return out;
  }

  private assertCanWrite(def: ResourceDef, actor: Actor, row?: Record<string, unknown>) {
    const access = def.write[actor.role];
    if (access === "all") return;
    if (access === "own" && def.ownerColumn) {
      if (!row || row[def.ownerColumn] === actor.salesId) return;
      throw new Forbidden("You can only modify records you own.");
    }
    throw new Forbidden("Your role cannot modify this resource.");
  }

  async create(resource: string, actor: Actor, data: Record<string, unknown>, ip?: string) {
    const def = this.def(resource);
    this.assertCanWrite(def, actor);
    const values = this.writableData(def, actor, data);
    if (def.ownerColumn) {
      const restricted = def.write[actor.role] === "own";
      if (restricted || values[def.ownerColumn] == null) values[def.ownerColumn] = actor.salesId;
    }
    const keys = Object.keys(values);
    if (keys.length === 0) throw new BadRequest("No writable fields supplied.");
    const p = new SqlParams();
    const placeholders = keys.map((k) => p.add(values[k]));
    return withTransaction(this.db, async (c) => {
      const { rows } = await c.query(
        `insert into ${quoteIdent(def.table)} (${keys.map(quoteIdent).join(", ")})
         values (${placeholders.join(", ")}) returning id`,
        p.values,
      );
      const id = rows[0].id;
      await audit(c, actor, "create", resource, id, values, ip);
      return this.readInTx(c, def, id);
    });
  }

  async update(resource: string, actor: Actor, id: string | number, data: Record<string, unknown>, ip?: string) {
    const def = this.def(resource);
    return withTransaction(this.db, async (c) => {
      const current = await this.lockRow(c, def, id);
      this.assertCanWrite(def, actor, current);
      const values = this.writableData(def, actor, data);
      if (def.ownerColumn && def.write[actor.role] === "own" && def.ownerColumn in values) {
        if (values[def.ownerColumn] !== actor.salesId) throw new Forbidden("You cannot reassign records.");
      }
      const changed = Object.keys(values).filter((k) => JSON.stringify(current[k]) !== JSON.stringify(values[k]));
      if (changed.length > 0) {
        const p = new SqlParams();
        const sets = changed.map((k) => `${quoteIdent(k)} = ${p.add(values[k])}`);
        await c.query(`update ${quoteIdent(def.table)} set ${sets.join(", ")} where id = ${p.add(id)}`, p.values);
        await audit(c, actor, "update", resource, id, Object.fromEntries(changed.map((k) => [k, values[k]])), ip);
      }
      return this.readInTx(c, def, id);
    });
  }

  async delete(resource: string, actor: Actor, id: string | number, ip?: string) {
    const def = this.def(resource);
    return withTransaction(this.db, async (c) => {
      const current = await this.lockRow(c, def, id);
      this.assertCanWrite(def, actor, current);
      const before = await this.readInTx(c, def, id);
      await c.query(`delete from ${quoteIdent(def.table)} where id = $1`, [id]);
      await audit(c, actor, "delete", resource, id, null, ip);
      return before;
    });
  }

  private async lockRow(c: DbClient, def: ResourceDef, id: string | number) {
    const { rows } = await c.query(`select * from ${quoteIdent(def.table)} where id = $1 for update`, [id]);
    if (!rows[0]) throw new NotFound(`Record ${id} not found`);
    return rows[0] as Record<string, unknown>;
  }

  private async readInTx(c: DbClient, def: ResourceDef, id: unknown) {
    const { rows } = await c.query(`select * from ${quoteIdent(def.readRelation)} where id = $1`, [id]);
    return publicRow(rows[0]);
  }
}

export async function audit(
  c: DbClient | Db,
  actor: Pick<Actor, "salesId" | "kind"> | null,
  action: string,
  resource: string | null,
  recordId: unknown,
  changes: unknown,
  ip?: string,
): Promise<void> {
  await c.query(
    `insert into audit_log (actor_sales_id, actor_kind, action, resource, record_id, changes, ip)
     values ($1, $2, $3, $4, $5, $6, $7)`,
    [
      actor?.salesId ?? null,
      actor?.kind ?? (actor ? "user" : "system"),
      action,
      resource,
      recordId == null ? null : String(recordId),
      changes == null ? null : JSON.stringify(changes),
      ip ?? null,
    ],
  );
}
