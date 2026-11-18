import pg from "pg";

// bigint (int8) -> JS number. CRM ids/amounts stay far below 2^53.
pg.types.setTypeParser(20, (v) => Number(v));
// bigint[] (e.g. deals.contact_ids, contacts.tags) -> number[]; the UI compares ids by value.
const INT8_ARRAY = 1016 as unknown as Parameters<typeof pg.types.getTypeParser>[0]; // not in pg's builtin TypeId enum
const parseTextArray = pg.types.getTypeParser(INT8_ARRAY) as (v: string) => (string | null)[];
pg.types.setTypeParser(INT8_ARRAY, (v: string) => parseTextArray(v).map((x) => (x === null ? null : Number(x))));
// date -> keep 'YYYY-MM-DD' string (avoid timezone shifts on date-only columns)
pg.types.setTypeParser(1082, (v) => v);

export type Db = pg.Pool;
export type DbClient = pg.PoolClient;

export function createPool(connectionString: string, max = 8): Db {
  return new pg.Pool({
    connectionString,
    max,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
    statement_timeout: 15_000,
    application_name: "crm-api",
  });
}

export async function withTransaction<T>(db: Db, fn: (client: DbClient) => Promise<T>): Promise<T> {
  const client = await db.connect();
  try {
    await client.query("begin");
    const result = await fn(client);
    await client.query("commit");
    return result;
  } catch (error) {
    await client.query("rollback").catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}
