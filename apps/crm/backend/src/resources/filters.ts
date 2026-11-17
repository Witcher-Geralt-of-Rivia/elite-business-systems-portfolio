/**
 * Translates the react-admin / PostgREST-style filter grammar used by the Atomic CRM UI
 * ("field@op": value, "@or": {...}, "q": text) into parameterized SQL.
 *
 * Supported ops (inventory of the upstream UI): eq neq lt lte gt gte like ilike in cs cd ov is not.is
 * Unknown fields or operators are rejected (400), never interpolated.
 */
import { arrayCast, BadRequest, type Columns, quoteIdent, toDbValue } from "./schema.ts";

const COMPARISON: Record<string, string> = { eq: "=", neq: "<>", lt: "<", lte: "<=", gt: ">", gte: ">=" };

export class SqlParams {
  values: unknown[] = [];
  add(value: unknown): string {
    this.values.push(value);
    return `$${this.values.length}`;
  }
}

function escapeLike(text: string): string {
  return text.replace(/[\\%_]/g, (c) => `\\${c}`);
}

function parseList(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  if (typeof value === "string") {
    const trimmed = value.replace(/^[({]|[)}]$/g, "");
    return trimmed === "" ? [] : trimmed.split(",").map((s) => s.trim());
  }
  return [value];
}

function condition(field: string, op: string, value: unknown, cols: Columns, p: SqlParams): string {
  const col = cols.get(field);
  if (!col) throw new BadRequest(`Unknown filter field: ${field}`);
  const ident = quoteIdent(field);

  if (op in COMPARISON) {
    if (value === null) return op === "neq" ? `${ident} is not null` : `${ident} is null`;
    if (op === "neq") return `${ident} is distinct from ${p.add(value)}`;
    return `${ident} ${COMPARISON[op]} ${p.add(value)}`;
  }
  switch (op) {
    case "like":
    case "ilike": {
      const pattern = `%${escapeLike(String(value).replace(/\*/g, ""))}%`;
      return `${ident}::text ${op} ${p.add(pattern)}`;
    }
    case "in": {
      const list = parseList(value);
      if (list.length === 0) return "false";
      return `${ident} = any(${p.add(list)})`;
    }
    case "cs":
    case "cd":
    case "ov": {
      const sqlOp = op === "cs" ? "@>" : op === "cd" ? "<@" : "&&";
      if (col.udtName === "jsonb") return `${ident} ${sqlOp} ${p.add(toDbValue(col, value))}::jsonb`;
      const cast = arrayCast(col);
      if (!cast) throw new BadRequest(`Operator ${op} needs an array column: ${field}`);
      return `${ident} ${sqlOp} ${p.add(parseList(value))}::${cast}`;
    }
    case "is":
    case "not.is": {
      const neg = op === "not.is" ? " not" : "";
      if (value === null || value === "null") return `${ident} is${neg} null`;
      if (value === true || value === "true") return `${ident} is${neg} true`;
      if (value === false || value === "false") return `${ident} is${neg} false`;
      throw new BadRequest(`Invalid value for ${op}`);
    }
    default:
      throw new BadRequest(`Unsupported filter operator: ${op}`);
  }
}

export function buildWhere(
  filter: Record<string, unknown>,
  cols: Columns,
  p: SqlParams,
  searchColumns: readonly string[] = [],
): string[] {
  const clauses: string[] = [];
  for (const [key, value] of Object.entries(filter)) {
    if (value === undefined || value === "") continue;
    if (key === "q") {
      if (searchColumns.length === 0) throw new BadRequest("This resource does not support search");
      const pattern = p.add(`%${escapeLike(String(value))}%`);
      clauses.push(`(${searchColumns.map((c) => `${quoteIdent(c)}::text ilike ${pattern}`).join(" or ")})`);
      continue;
    }
    if (key === "@or") {
      if (typeof value !== "object" || value === null) throw new BadRequest("@or expects an object");
      const parts = buildWhere(value as Record<string, unknown>, cols, p);
      if (parts.length) clauses.push(`(${parts.join(" or ")})`);
      continue;
    }
    const at = key.indexOf("@");
    const field = at === -1 ? key : key.slice(0, at);
    const op = at === -1 ? (Array.isArray(value) ? "in" : "eq") : key.slice(at + 1);
    clauses.push(condition(field, op, value, cols, p));
  }
  return clauses;
}

export function buildOrderBy(sort: string | undefined, order: string | undefined, cols: Columns): string {
  if (!sort) return cols.has("id") ? `order by "id" asc` : "";
  if (!cols.has(sort)) throw new BadRequest(`Unknown sort field: ${sort}`);
  const dir = String(order).toUpperCase() === "DESC" ? "desc" : "asc";
  return `order by ${quoteIdent(sort)} ${dir} nulls last${sort !== "id" && cols.has("id") ? `, "id" ${dir}` : ""}`;
}
