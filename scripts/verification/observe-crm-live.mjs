/**
 * Observes the production CRM's live simulation during a business window and writes JSON evidence:
 *  - starts a read-only visitor session on the public URL and listens to /api/events (SSE), like a browser;
 *  - polls the database for companies created by the simulator after the start, with their audit events;
 *  - stops after the first new lead + 10 minutes of observation, or after --minutes.
 *
 * Usage (run from C:\srv\portfolio\crm\api so `pg` resolves):
 *   node <repo>/scripts/verification/observe-crm-live.mjs --ip <PUBLIC_IP> --env C:\srv\portfolio\secrets\crm-api.env --out <file.json> [--minutes 360]
 */
import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { parseArgs } from "node:util";

const { values } = parseArgs({
  options: { ip: { type: "string" }, env: { type: "string" }, out: { type: "string" }, minutes: { type: "string", default: "360" } },
});
const require = createRequire(process.cwd() + "/");
const pg = require("pg");
const env = Object.fromEntries(
  readFileSync(values.env, "utf8").split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]),
);
const base = `https://crm.${values.ip}.sslip.io`;
const started = new Date();
const deadline = Date.now() + Number(values.minutes) * 60_000;
const report = { started: started.toISOString(), base: "https://crm.<VPS_IP>.sslip.io", sse: { connected: false, changeEvents: 0, companyInserts: [], errors: [] }, leads: [], finished: null };

const save = () => writeFileSync(values.out, JSON.stringify(report, null, 2));

async function visitorCookie() {
  const res = await fetch(`${base}/api/auth/showcase`, { method: "POST", headers: { "X-CRM-CSRF": "1", "Content-Type": "application/json" }, body: "{}" });
  if (!res.ok) throw new Error(`showcase login ${res.status}`);
  return res.headers.get("set-cookie").split(";")[0];
}

async function listen() {
  while (Date.now() < deadline) {
    try {
      const cookie = await visitorCookie();
      const res = await fetch(`${base}/api/events`, { headers: { cookie } });
      report.sse.connected = res.ok;
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      while (Date.now() < deadline) {
        const { value, done } = await reader.read();
        if (done) break; // server closes streams every few minutes: reconnect
        buffer += decoder.decode(value);
        let i;
        while ((i = buffer.indexOf("\n\n")) >= 0) {
          const block = buffer.slice(0, i);
          buffer = buffer.slice(i + 2);
          if (!block.startsWith("event: change")) continue;
          report.sse.changeEvents++;
          const data = JSON.parse(block.split("\ndata: ")[1]);
          if (data.table === "companies" && data.op === "insert") report.sse.companyInserts.push({ at: new Date().toISOString(), id: data.id });
        }
      }
    } catch (error) {
      report.sse.errors.push(String(error).slice(0, 200));
      await new Promise((r) => setTimeout(r, 15_000));
    }
  }
}

async function poll() {
  const client = new pg.Client({ connectionString: env.CRM_DATABASE_URL });
  await client.connect();
  await client.query("set search_path = crm");
  let firstLeadAt = null;
  while (Date.now() < deadline) {
    const { rows } = await client.query(
      `select c.id, c.name, c.created_at, s.first_name || ' ' || s.last_name as owner,
              (select count(*)::int from audit_log a where a.resource = 'companies' and a.record_id = c.id::text
                and a.action = 'create' and a.actor_kind = 'simulator') as audit_events,
              (select count(*)::int from contacts x where x.company_id = c.id) as contacts
         from companies c join sales s on s.id = c.sales_id
        where c.created_at >= $1 order by c.id`,
      [started],
    );
    report.leads = rows;
    if (rows.length && !firstLeadAt) firstLeadAt = Date.now();
    report.sse.matchedInDatabase = report.sse.companyInserts.filter((e) => rows.some((r) => Number(r.id) === Number(e.id))).length;
    save();
    if (firstLeadAt && Date.now() - firstLeadAt > 10 * 60_000) break;
    await new Promise((r) => setTimeout(r, 60_000));
  }
  await client.end();
}

const listener = listen();
await poll();
report.finished = new Date().toISOString();
save();
process.exit(0);
void listener;
