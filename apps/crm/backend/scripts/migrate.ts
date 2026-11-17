/**
 * Applies migrations/*.sql in lexical order, each in its own transaction, as role crm_owner.
 * Connects with CRM_MIGRATION_DATABASE_URL (a privileged role that is a member of crm_owner).
 * Records version + sha256 in crm.schema_migrations and refuses to run if an applied file changed.
 */
import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import pg from "pg";

const url = process.env.CRM_MIGRATION_DATABASE_URL;
if (!url) throw new Error("CRM_MIGRATION_DATABASE_URL is required");

const dir = join(import.meta.dirname, "..", "migrations");
const client = new pg.Client({ connectionString: url, application_name: "crm-migrate" });
await client.connect();

try {
  await client.query(`set role crm_owner`);
  await client.query(`create table if not exists crm.schema_migrations (
      version text primary key, checksum text not null, applied_at timestamptz not null default now())`);
  const applied = new Map<string, string>(
    (await client.query(`select version, checksum from crm.schema_migrations`)).rows.map((r) => [r.version, r.checksum]),
  );

  const files = (await readdir(dir)).filter((f) => f.endsWith(".sql")).sort();
  for (const file of files) {
    const sql = await readFile(join(dir, file), "utf8");
    const checksum = createHash("sha256").update(sql).digest("hex");
    const version = file.replace(/\.sql$/, "");
    const prior = applied.get(version);
    if (prior) {
      if (prior !== checksum) throw new Error(`Applied migration ${file} was modified (checksum mismatch)`);
      continue;
    }
    console.log(`applying ${file}`);
    await client.query("begin");
    try {
      await client.query(`set local role crm_owner; set local search_path = crm;`);
      await client.query(sql);
      await client.query(`insert into crm.schema_migrations (version, checksum) values ($1, $2)`, [version, checksum]);
      await client.query("commit");
    } catch (error) {
      await client.query("rollback");
      throw error;
    }
  }
  console.log("migrations up to date");
} finally {
  await client.end();
}
