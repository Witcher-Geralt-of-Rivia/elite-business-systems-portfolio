/**
 * PoC acceptance tests (D-009): authentication, one complete CRUD workflow, persistence,
 * server-enforced permissions, CSRF and filter safety. Runs against the crm_test database.
 */
import assert from "node:assert/strict";
import { after, before, describe, test } from "node:test";
import pg from "pg";
import type { FastifyInstance } from "fastify";
import { buildApp, CSRF_HEADER } from "../src/app.ts";
import { hashPassword } from "../src/auth/password.ts";
import { loadConfig } from "../src/config.ts";
import { createPool, type Db } from "../src/db.ts";

// Generous login budget for the shared app; the limiter itself is tested on a dedicated instance.
const config = { ...loadConfig(), cookieSecure: true, logLevel: "silent", loginRateLimitPerMinute: 1000 };
assert.match(config.databaseUrl, /\/crm_test(\?|$)/, "tests must run against crm_test");

const PASSWORD = "correct-horse-battery-staple";
let db: Db;
let app: FastifyInstance;
const ids: Record<string, number> = {};

async function seedUser(email: string, first: string, last: string, role: string): Promise<number> {
  const { rows } = await db.query(`insert into users (email, password_hash) values ($1, $2) returning id`, [
    email,
    await hashPassword(PASSWORD),
  ]);
  const sale = await db.query(
    `insert into sales (first_name, last_name, email, role, user_id) values ($1, $2, $3, $4, $5) returning id`,
    [first, last, email, role, rows[0].id],
  );
  return sale.rows[0].id;
}

async function login(email: string, password = PASSWORD) {
  return app.inject({
    method: "POST",
    url: "/api/auth/login",
    headers: { [CSRF_HEADER]: "1", origin: config.publicOrigin },
    payload: { email, password },
  });
}

function cookieOf(res: { headers: Record<string, unknown> }): string {
  const raw = res.headers["set-cookie"];
  const first = Array.isArray(raw) ? raw[0] : String(raw);
  return first.split(";")[0];
}

function api(cookie: string) {
  const headers = { cookie, [CSRF_HEADER]: "1", origin: config.publicOrigin };
  return {
    get: (url: string) => app.inject({ method: "GET", url, headers: { cookie } }),
    post: (url: string, payload: object) => app.inject({ method: "POST", url, headers, payload }),
    patch: (url: string, payload: object) => app.inject({ method: "PATCH", url, headers, payload }),
    put: (url: string, payload: object) => app.inject({ method: "PUT", url, headers, payload }),
    del: (url: string) => app.inject({ method: "DELETE", url, headers }),
  };
}

const listUrl = (resource: string, filter: object, extra = "") =>
  `/api/r/${resource}?filter=${encodeURIComponent(JSON.stringify(filter))}${extra}`;

before(async () => {
  db = createPool(config.databaseUrl, 4);
  await db.query(`delete from audit_log; delete from sessions; delete from tasks; delete from contact_notes;
                  delete from deal_notes; delete from deals; delete from contacts; delete from companies;
                  delete from tags; delete from sales; delete from users;`);
  ids.admin = await seedUser("ada.lindqvist@example.com", "Ada", "Lindqvist", "admin");
  ids.rep = await seedUser("marco.ferrante@example.com", "Marco", "Ferrante", "sales_rep");
  ids.visitor = await seedUser("visitor@example.org", "Guest", "Visitor", "showcase");
  app = await buildApp(config, db);
});

after(async () => {
  await app?.close();
  await db?.end();
});

describe("authentication", () => {
  test("rejects unauthenticated access to business data", async () => {
    const res = await app.inject({ method: "GET", url: "/api/r/contacts" });
    assert.equal(res.statusCode, 401);
  });

  test("rejects a wrong password with a generic message and audits it", async () => {
    const res = await login("ada.lindqvist@example.com", "not-the-password");
    assert.equal(res.statusCode, 401);
    assert.equal(res.json().error, "Invalid email or password.");
    const unknown = await login("nobody@example.com", "whatever-password");
    assert.equal(unknown.json().error, "Invalid email or password.");
    const { rows } = await db.query(`select count(*)::int as n from audit_log where action = 'login_failed'`);
    assert.ok(rows[0].n >= 2);
  });

  test("refuses login without the CSRF header or from a foreign origin", async () => {
    const noHeader = await app.inject({
      method: "POST",
      url: "/api/auth/login",
      payload: { email: "ada.lindqvist@example.com", password: PASSWORD },
    });
    assert.equal(noHeader.statusCode, 403);
    const foreign = await app.inject({
      method: "POST",
      url: "/api/auth/login",
      headers: { [CSRF_HEADER]: "1", origin: "https://evil.example.net" },
      payload: { email: "ada.lindqvist@example.com", password: PASSWORD },
    });
    assert.equal(foreign.statusCode, 403);
  });

  test("issues an httpOnly, Secure, SameSite session cookie and resolves identity", async () => {
    const res = await login("ada.lindqvist@example.com");
    assert.equal(res.statusCode, 200);
    const setCookie = String(res.headers["set-cookie"]);
    assert.match(setCookie, /HttpOnly/i);
    assert.match(setCookie, /Secure/i);
    assert.match(setCookie, /SameSite=Lax/i);
    assert.deepEqual(
      { fullName: res.json().fullName, role: res.json().role, administrator: res.json().administrator },
      { fullName: "Ada Lindqvist", role: "admin", administrator: true },
    );
    const me = await api(cookieOf(res)).get("/api/auth/me");
    assert.equal(me.json().id, ids.admin);
    // The raw token is never stored: only its sha256 hash.
    const token = cookieOf(res).split("=")[1];
    const { rows } = await db.query(`select count(*)::int as n from sessions where token_hash = $1`, [token]);
    assert.equal(rows[0].n, 0);
  });

  test("logout revokes the session server-side", async () => {
    const cookie = cookieOf(await login("ada.lindqvist@example.com"));
    const out = await api(cookie).post("/api/auth/logout", {});
    assert.equal(out.statusCode, 200);
    assert.equal((await api(cookie).get("/api/auth/me")).statusCode, 401);
  });
});

describe("CRUD workflow persisted in PostgreSQL", () => {
  let admin: ReturnType<typeof api>;

  before(async () => {
    admin = api(cookieOf(await login("ada.lindqvist@example.com")));
  });

  test("company -> contact -> deal -> note -> task, then update, search, delete", async () => {
    const tag = await admin.post("/api/r/tags", { name: "Enterprise", color: "#7dbde8" });
    assert.equal(tag.statusCode, 201);

    const company = await admin.post("/api/r/companies", {
      name: "Northwind Logistics Group",
      sector: "Transportation",
      city: "Columbus",
      website: "https://northwind-logistics.example.com",
      nb_contacts: 999, // computed view column: must be ignored, not stored
    });
    assert.equal(company.statusCode, 201, company.body);
    ids.company = company.json().data.id;
    assert.equal(company.json().data.sales_id, ids.admin, "owner defaults to the creator");
    assert.equal(company.json().data.nb_contacts, 0);

    const contact = await admin.post("/api/r/contacts", {
      first_name: "Priya",
      last_name: "Raman",
      title: "VP Operations",
      company_id: ids.company,
      tags: [tag.json().data.id],
      email_jsonb: [{ email: "priya.raman@northwind-logistics.example.com", type: "Work" }],
      phone_jsonb: [{ number: "+1 614 555 0142", type: "Work" }],
      first_seen: "2026-03-02T15:04:00Z",
      last_seen: "2026-11-10T09:30:00Z",
      status: "warm",
    });
    assert.equal(contact.statusCode, 201, contact.body);
    ids.contact = contact.json().data.id;
    assert.equal(contact.json().data.company_name, "Northwind Logistics Group");

    const deal = await admin.post("/api/r/deals", {
      name: "Fleet telematics rollout",
      company_id: ids.company,
      contact_ids: [ids.contact],
      categories: ["Implementation"],
      stage: "opportunity",
      amount: 184000,
      expected_closing_date: "2027-02-15",
      index: 0,
    });
    assert.equal(deal.statusCode, 201, deal.body);
    ids.deal = deal.json().data.id;

    const note = await admin.post("/api/r/contact_notes", {
      contact_id: ids.contact,
      text: "Discovery call: 340 vehicles, current vendor contract ends in Q1.",
      status: "warm",
      attachments: [{ src: "/api/files/placeholder", title: "fleet-inventory.xlsx", type: "application/vnd.ms-excel" }],
    });
    assert.equal(note.statusCode, 201, note.body);
    assert.equal(note.json().data.attachments[0].title, "fleet-inventory.xlsx");

    const task = await admin.post("/api/r/tasks", {
      contact_id: ids.contact,
      type: "Follow-up",
      text: "Send telematics pricing proposal",
      due_date: "2026-11-20T17:00:00Z",
    });
    assert.equal(task.statusCode, 201, task.body);
    ids.task = task.json().data.id;

    // contacts_summary computes open tasks
    const one = await admin.get(`/api/r/contacts/${ids.contact}`);
    assert.equal(one.json().data.nb_tasks, 1);

    // update: move the deal down the pipeline
    const moved = await admin.patch(`/api/r/deals/${ids.deal}`, { stage: "proposal-sent", amount: 176500 });
    assert.equal(moved.statusCode, 200, moved.body);
    assert.equal(moved.json().data.stage, "proposal-sent");
    assert.ok(new Date(moved.json().data.updated_at) >= new Date(deal.json().data.updated_at));
  });

  test("list filters used by the UI: q search, @or, array contains, is-null, getMany", async () => {
    const byQ = await admin.get(listUrl("contacts", { q: "northwind" }));
    assert.equal(byQ.json().total, 1);
    const byEmail = await admin.get(listUrl("contacts", { "@or": { "email_fts@ilike": "priya.raman", "last_name@ilike": "zzz" } }));
    assert.equal(byEmail.json().total, 1);
    const byTag = await admin.get(listUrl("contacts", { "tags@cs": `{${(await db.query("select id from tags")).rows[0].id}}` }));
    assert.equal(byTag.json().total, 1);
    const open = await admin.get(listUrl("deals", { "archived_at@is": null, stage: "proposal-sent" }, "&sort=amount&order=DESC"));
    assert.equal(open.json().data[0].id, ids.deal);
    const many = await admin.get(listUrl("contacts", { id: [ids.contact, 999999] }));
    assert.equal(many.json().total, 1);
  });

  test("data survives on a fresh database connection", async () => {
    const fresh = new pg.Client({ connectionString: config.databaseUrl });
    await fresh.connect();
    try {
      const { rows } = await fresh.query(
        `select d.stage, d.amount, c.name as company from deals d join companies c on c.id = d.company_id where d.id = $1`,
        [ids.deal],
      );
      // (int8 is parsed to number process-wide by src/db.ts)
      assert.deepEqual(rows[0], { stage: "proposal-sent", amount: 176500, company: "Northwind Logistics Group" });
    } finally {
      await fresh.end();
    }
  });

  test("delete removes the row and every mutation is audited", async () => {
    const del = await admin.del(`/api/r/tasks/${ids.task}`);
    assert.equal(del.statusCode, 200);
    assert.equal((await admin.get(`/api/r/tasks/${ids.task}`)).statusCode, 404);
    const { rows } = await db.query(
      `select action, resource from audit_log where actor_sales_id = $1 and resource <> 'auth' order by id`,
      [ids.admin],
    );
    const actions = rows.map((r) => `${r.action}:${r.resource}`);
    for (const expected of ["create:companies", "create:contacts", "create:deals", "update:deals", "delete:tasks"]) {
      assert.ok(actions.includes(expected), `missing audit entry ${expected}`);
    }
  });
});

describe("server-enforced permissions", () => {
  test("sales rep: reads team data, edits own records only, cannot reassign", async () => {
    const rep = api(cookieOf(await login("marco.ferrante@example.com")));
    assert.equal((await rep.get(`/api/r/companies/${ids.company}`)).statusCode, 200);
    assert.equal((await rep.patch(`/api/r/companies/${ids.company}`, { city: "Dayton" })).statusCode, 403);
    assert.equal((await rep.del(`/api/r/deals/${ids.deal}`)).statusCode, 403);

    const own = await rep.post("/api/r/companies", { name: "Harborline Medical Supply", sales_id: ids.admin });
    assert.equal(own.statusCode, 201);
    assert.equal(own.json().data.sales_id, ids.rep, "reps cannot create records on behalf of others");
    const id = own.json().data.id;
    assert.equal((await rep.patch(`/api/r/companies/${id}`, { city: "Tacoma" })).statusCode, 200);
    assert.equal((await rep.patch(`/api/r/companies/${id}`, { sales_id: ids.admin })).statusCode, 403);
  });

  test("showcase visitor is read-only; nobody edits team members through the generic API", async () => {
    const visitor = api(cookieOf(await login("visitor@example.org")));
    assert.equal((await visitor.get(listUrl("deals", {}))).statusCode, 200);
    assert.equal((await visitor.post("/api/r/tags", { name: "x", color: "#000" })).statusCode, 403);
    const admin = api(cookieOf(await login("ada.lindqvist@example.com")));
    assert.equal((await admin.patch(`/api/r/sales/${ids.rep}`, { role: "admin" })).statusCode, 403);
  });
});

describe("configuration", () => {
  test("team reads settings; only administrators change them", async () => {
    const admin = api(cookieOf(await login("ada.lindqvist@example.com")));
    const visitor = api(cookieOf(await login("visitor@example.org")));
    const settings = { title: "Meridian Advisory CRM", dealStages: [{ value: "opportunity", label: "Opportunity" }] };
    const put = await admin.put("/api/configuration", settings);
    assert.equal(put.statusCode, 200, put.body);
    assert.deepEqual((await visitor.get("/api/configuration")).json().data, settings);
    assert.equal((await visitor.put("/api/configuration", { title: "defaced" })).statusCode, 403);
    assert.equal((await admin.get("/api/configuration")).json().data.title, "Meridian Advisory CRM");
  });
});

describe("input safety", () => {
  test("rejects unknown filter fields, operators and sort columns instead of interpolating them", async () => {
    const admin = api(cookieOf(await login("ada.lindqvist@example.com")));
    assert.equal((await admin.get(listUrl("contacts", { "id; drop table contacts--": 1 }))).statusCode, 400);
    assert.equal((await admin.get(listUrl("contacts", { "first_name@regex": ".*" }))).statusCode, 400);
    assert.equal((await admin.get(listUrl("contacts", {}, "&sort=id;drop%20table%20x"))).statusCode, 400);
    assert.equal((await admin.get("/api/r/users")).statusCode, 404, "auth tables are not exposed");
    const { rows } = await db.query(`select count(*)::int as n from contacts`);
    assert.ok(rows[0].n >= 1);
  });

  test("rate-limits login attempts per client at the production budget (10/min)", async () => {
    const limited = await buildApp({ ...config, loginRateLimitPerMinute: 10 }, db);
    try {
      const statuses: number[] = [];
      for (let i = 0; i < 11; i++) {
        const res = await limited.inject({
          method: "POST",
          url: "/api/auth/login",
          headers: { [CSRF_HEADER]: "1", origin: config.publicOrigin },
          payload: { email: "nobody@example.com", password: "irrelevant-password" },
        });
        statuses.push(res.statusCode);
      }
      assert.deepEqual(statuses.slice(0, 10), Array(10).fill(401));
      assert.equal(statuses[10], 429);
    } finally {
      await limited.close();
    }
  });

  test("locks the account after repeated failures (independent of the rate limiter)", async () => {
    const fresh = await buildApp(config, db); // fresh in-memory rate-limit budget
    try {
      const attempt = (password: string) =>
        fresh.inject({
          method: "POST",
          url: "/api/auth/login",
          headers: { [CSRF_HEADER]: "1", origin: config.publicOrigin },
          payload: { email: "marco.ferrante@example.com", password },
        });
      for (let i = 0; i < 5; i++) assert.equal((await attempt("wrong-password-attempt")).statusCode, 401);
      const res = await attempt(PASSWORD);
      assert.equal(res.statusCode, 401, "correct password refused while locked");
      const { rows } = await db.query(
        `select locked_until > now() as locked from users where email = 'marco.ferrante@example.com'`,
      );
      assert.equal(rows[0].locked, true);
    } finally {
      await fresh.close();
    }
  });
});
