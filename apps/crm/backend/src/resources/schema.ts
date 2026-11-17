import type { Db } from "../db.ts";

export interface ColumnInfo {
  name: string;
  dataType: string; // information_schema data_type, e.g. 'bigint', 'jsonb', 'ARRAY'
  udtName: string; // e.g. 'int8', '_int8', '_text', '_jsonb'
  isGenerated: boolean;
  isIdentityAlways: boolean;
}

export type Columns = Map<string, ColumnInfo>;
export type SchemaInfo = Map<string, Columns>; // relation name -> columns

/** Loads column metadata for every table and view in the crm schema. */
export async function loadSchema(db: Db): Promise<SchemaInfo> {
  const { rows } = await db.query(
    `select table_name, column_name, data_type, udt_name, is_generated, identity_generation
       from information_schema.columns
      where table_schema = 'crm'
      order by table_name, ordinal_position`,
  );
  const schema: SchemaInfo = new Map();
  for (const r of rows) {
    if (!schema.has(r.table_name)) schema.set(r.table_name, new Map());
    schema.get(r.table_name)!.set(r.column_name, {
      name: r.column_name,
      dataType: r.data_type,
      udtName: r.udt_name,
      isGenerated: r.is_generated === "ALWAYS",
      isIdentityAlways: r.identity_generation === "ALWAYS",
    });
  }
  return schema;
}

const ARRAY_CASTS: Record<string, string> = {
  _int8: "bigint[]",
  _int4: "integer[]",
  _text: "text[]",
  _jsonb: "jsonb[]",
};

export function arrayCast(col: ColumnInfo): string | null {
  return ARRAY_CASTS[col.udtName] ?? null;
}

/** Serializes a JS value for a parameter bound to `col`, so node-pg sends the right wire format. */
export function toDbValue(col: ColumnInfo, value: unknown): unknown {
  if (value === undefined) return undefined;
  if (value === null) return null;
  if (col.udtName === "jsonb" || col.udtName === "json") return JSON.stringify(value);
  if (col.udtName === "_jsonb") {
    if (!Array.isArray(value)) throw new BadRequest(`${col.name} must be an array`);
    return value.map((v) => JSON.stringify(v));
  }
  return value;
}

export function quoteIdent(name: string): string {
  if (!/^[a-z_][a-z0-9_]*$/.test(name)) throw new BadRequest(`Invalid identifier: ${name}`);
  return `"${name}"`;
}

export class BadRequest extends Error {
  statusCode = 400;
}
export class Forbidden extends Error {
  statusCode = 403;
}
export class NotFound extends Error {
  statusCode = 404;
}
