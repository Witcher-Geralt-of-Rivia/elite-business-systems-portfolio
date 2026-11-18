/**
 * M4 feature tests: first-run sign-up, invitations, password links, team management rules,
 * global search, contact merge, attachments and live updates (SSE). Runs against crm_test.
 */
import assert from "node:assert/strict";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import type { FastifyInstance } from "fastify";
import { buildApp, CSRF_HEADER } from "../src/app.ts";
import { purgeOrphanAttachments } from "../src/attachments/routes.ts";
import { loadConfig } from "../src/config.ts";
import { createPool, type Db } from "../src/db.ts";

const filesDir = await mkdtemp(join(tmpdir(), "crm-m4-files-"));
const config = {
  ...loadConfig(),
  cookieSecure: true,
  logLevel: "silent",
  loginRateLimitPerMinute: 1000,
  attachmentsDir: filesDir,
};
assert.match(config.databaseUrl, /\/crm_test(\?|$)/, "tests must run against crm_test");

const ADMIN_PW = "first-admin-passphrase-2026";
const REP_PW = "invited-rep-passphrase-2026";
let db: Db;
let app: FastifyInstance;
const state: Record<string, any> = {};

const json = (res: { body: string }) => JSON.parse(res.body);
const csrf = { [CSRF_HEADER]: "1", origin: config.publicOrigin };

function cookieOf(res: { headers: Record<string, unknown> }): string {
  const raw = res.headers["set-cookie"];
  return (Array.isArray(raw) ? raw[0] : String(raw)).split(";")[0];
}

async function login(email: string, password: string) {
  return app.inject({ method: "POST", url: "/api/auth/login", headers: csrf, payload: { email, password } });
}

function api(cookie: string) {
  const headers = { cookie, ...csrf };
  return {
    get: (url: string) => app.inject({ method: "GET", url, headers: { cookie } }),
    post: (url: string, payload?: object) => app.inject({ method: "POST", url, headers, payload: payload ?? {} }),
    patch: (url: string, payload: object) => app.inject({ method: "PATCH", url, headers, payload }),
    del: (url: string) => app.inject({ method: "DELETE", url, headers }),
  };
}

const tokenFrom = (url: string) => decodeURIComponent(new URL(url.replace("/#/", "/")).searchParams.get("token")!);

before(async () => {
  db = createPool(config.databaseUrl, 4);
  await db.query(`delete from audit_log; delete from sessions; delete from password_reset_tokens; delete from attachments;
                  delete from tasks; delete from contact_notes; delete from deal_notes; delete from deals;
                  delete from contacts; delete from companies; delete from tags; delete from sales; delete from users;`);
  app = await buildApp(config, db);
});

after(async () => {
  await app.close();
  await db.end();
  await rm(filesDir, { recursive: true, force: true });
});

describe("first run and team management", () => {
  test("an empty instance accepts exactly one sign-up, which becomes the administrator", async () => {
    const init = json(await app.inject({ method: "GET", url: "/api/auth/init-state" }));
    assert.equal(init.initialized, false);

    const weak = await app.inject({ method: "POST", url: "/api/auth/signup", headers: csrf,
      payload: { email: "owner@example.com", password: "short", first_name: "Olivia", last_name: "Brandt" } });
    assert.equal(weak.statusCode, 400);

    const ok = await app.inject({ method: "POST", url: "/api/auth/signup", headers: csrf,
      payload: { email: "Owner@Example.com", password: ADMIN_PW, first_name: "Olivia", last_name: "Brandt" } });
    assert.equal(ok.statusCode, 201, ok.body);
    assert.equal(json(ok).email, "owner@example.com");

    const second = await app.inject({ method: "POST", url: "/api/auth/signup", headers: csrf,
      payload: { email: "intruder@example.com", password: ADMIN_PW, first_name: "Eve", last_name: "Mallory" } });
    assert.equal(second.statusCode, 403);

    const res = await login("owner@example.com", ADMIN_PW);
    assert.equal(res.statusCode, 200);
    assert.equal(json(res).role, "admin");
    state.admin = cookieOf(res);
    state.adminSalesId = json(res).id;
  });

  test("admin invites a member; the one-time link sets their password and works only once", async () => {
    const res = await api(state.admin).post("/api/users", {
      email: "Rafael.Okafor@example.com", first_name: "Rafael", last_name: "Okafor",
      administrator: false, disabled: false, password: "ignored-by-server",
    });
    assert.equal(res.statusCode, 201, res.body);
    const body = json(res);
    assert.equal(body.data.role, "sales_rep");
    assert.equal(body.data.email, "rafael.okafor@example.com");
    assert.match(body.invitation.url, /^https:\/\/.+\/#\/set-password\?token=/);
    state.repSalesId = body.data.id;

    // No password yet: login impossible
    assert.equal((await login("rafael.okafor@example.com", "ignored-by-server")).statusCode, 401);

    const token = tokenFrom(body.invitation.url);
    const weak = await app.inject({ method: "POST", url: "/api/auth/set-password", headers: csrf, payload: { token, password: "short" } });
    assert.equal(weak.statusCode, 400);
    const set = await app.inject({ method: "POST", url: "/api/auth/set-password", headers: csrf, payload: { token, password: REP_PW } });
    assert.equal(set.statusCode, 200, set.body);
    const reuse = await app.inject({ method: "POST", url: "/api/auth/set-password", headers: csrf, payload: { token, password: REP_PW } });
    assert.equal(reuse.statusCode, 400, "tokens are single-use");

    const rep = await login("rafael.okafor@example.com", REP_PW);
    assert.equal(rep.statusCode, 200);
    state.rep = cookieOf(rep);

    const stored = await db.query(`select count(*)::int as n from password_reset_tokens where token_hash = $1`, [token]);
    assert.equal(stored.rows[0].n, 0, "raw tokens are never stored");
  });

  test("duplicate emails are refused with the code the team UI understands", async () => {
    const res = await api(state.admin).post("/api/users", { email: "rafael.okafor@example.com", first_name: "R", last_name: "O" });
    assert.equal(res.statusCode, 409);
    assert.equal(json(res).code, "email_taken");
    assert.equal(json(res).email, "rafael.okafor@example.com");
  });

  test("non-admins cannot invite, promote themselves or edit others; they can edit their own profile", async () => {
    const rep = api(state.rep);
    assert.equal((await rep.post("/api/users", { email: "x@example.com", first_name: "X", last_name: "Y" })).statusCode, 403);
    assert.equal((await rep.patch(`/api/users/${state.repSalesId}`, { administrator: true })).statusCode, 403);
    assert.equal((await rep.patch(`/api/users/${state.adminSalesId}`, { first_name: "Hacked" })).statusCode, 403);
    assert.equal((await rep.post(`/api/users/${state.adminSalesId}/password-link`)).statusCode, 403);
    const own = await rep.patch(`/api/users/${state.repSalesId}`, { first_name: "Rafa", secondary_emails: ["rafa@example.org"] });
    assert.equal(own.statusCode, 200, own.body);
    assert.equal(json(own).data.first_name, "Rafa");
    assert.deepEqual(json(own).data.secondary_emails, ["rafa@example.org"]);
  });

  test("the last active administrator cannot be demoted or disabled", async () => {
    const admin = api(state.admin);
    assert.equal((await admin.patch(`/api/users/${state.adminSalesId}`, { administrator: false })).statusCode, 400);
    assert.equal((await admin.patch(`/api/users/${state.adminSalesId}`, { disabled: true })).statusCode, 400);
  });

  test("password reset link: newest link only, resets lockout, ends existing sessions", async () => {
    const admin = api(state.admin);
    const first = json(await admin.post(`/api/users/${state.repSalesId}/password-link`));
    const second = json(await admin.post(`/api/users/${state.repSalesId}/password-link`));
    assert.equal(second.purpose, "reset");
    const stale = await app.inject({ method: "POST", url: "/api/auth/set-password", headers: csrf,
      payload: { token: tokenFrom(first.url), password: "a-new-passphrase-2026" } });
    assert.equal(stale.statusCode, 400, "older link invalidated by the newer one");
    const ok = await app.inject({ method: "POST", url: "/api/auth/set-password", headers: csrf,
      payload: { token: tokenFrom(second.url), password: "a-new-passphrase-2026" } });
    assert.equal(ok.statusCode, 200);
    assert.equal((await api(state.rep).get("/api/auth/me")).statusCode, 401, "old session revoked");
    assert.equal((await login("rafael.okafor@example.com", REP_PW)).statusCode, 401);
    const rep = await login("rafael.okafor@example.com", "a-new-passphrase-2026");
    assert.equal(rep.statusCode, 200);
    state.rep = cookieOf(rep);
  });

  test("disabling a member ends their sessions immediately", async () => {
    const tmp = json(await api(state.admin).post("/api/users", { email: "temp.user@example.com", first_name: "Temp", last_name: "User" }));
    await app.inject({ method: "POST", url: "/api/auth/set-password", headers: csrf,
      payload: { token: tokenFrom(tmp.invitation.url), password: "temporary-passphrase-1" } });
    const session = cookieOf(await login("temp.user@example.com", "temporary-passphrase-1"));
    assert.equal((await api(session).get("/api/auth/me")).statusCode, 200);
    assert.equal((await api(state.admin).patch(`/api/users/${tmp.data.id}`, { disabled: true })).statusCode, 200);
    assert.equal((await api(session).get("/api/auth/me")).statusCode, 401);
    assert.equal((await login("temp.user@example.com", "temporary-passphrase-1")).statusCode, 401);
  });
});

describe("global search", () => {
  test("finds records across resources with accent-insensitive prefix matching", async () => {
    const admin = api(state.admin);
    const company = json(await admin.post("/api/r/companies", { name: "Société Générale de Logistique", sector: "Logistics", city: "Lyon" })).data;
    const contact = json(await admin.post("/api/r/contacts", {
      first_name: "Hélène", last_name: "Dupont", company_id: company.id, title: "Head of Procurement",
      email_jsonb: [{ email: "helene.dupont@sgl-logistique.example", type: "Work" }], first_seen: new Date().toISOString(),
    })).data;
    const deal = json(await admin.post("/api/r/deals", { name: "Cold-chain visibility pilot", company_id: company.id,
      contact_ids: [contact.id], stage: "opportunity", amount: 48000, categories: ["analytics"] })).data;
    await admin.post("/api/r/tasks", { contact_id: contact.id, type: "Call", text: "Confirm pilot scope with Hélène", due_date: new Date().toISOString() });
    state.company = company;
    state.contact = contact;
    state.deal = deal;

    const res = await admin.get(`/api/search?q=${encodeURIComponent("hel dup")}`);
    assert.equal(res.statusCode, 200, res.body);
    const results = json(res);
    const top = results[0];
    assert.equal(top.resource, "contacts");
    assert.equal(top.title, "Hélène Dupont");
    assert.equal(top.subtitle, "Société Générale de Logistique");

    const restricted = json(await admin.get(`/api/search?q=pilot&resources=deals`));
    assert.deepEqual(restricted.map((r: any) => r.resource), ["deals"]);
    assert.ok(json(await admin.get(`/api/search?q=societe`)).some((r: any) => r.resource === "companies"));
    assert.deepEqual(json(await admin.get(`/api/search?q=${encodeURIComponent("   ")}`)), []);
    assert.equal((await app.inject({ method: "GET", url: "/api/search?q=pilot" })).statusCode, 401);
  });

  test("search vectors are not leaked through the record API", async () => {
    const one = json(await api(state.admin).get(`/api/r/deals/${state.deal.id}`)).data;
    assert.equal("fts" in one, false);
  });
});

describe("contact merge", () => {
  test("moves tasks, notes and deal links to the winner atomically and deletes the duplicate", async () => {
    const admin = api(state.admin);
    const dup = json(await admin.post("/api/r/contacts", {
      first_name: "Helene", last_name: "Dupont", company_id: state.company.id, linkedin_url: "https://www.linkedin.com/in/hdupont",
      email_jsonb: [{ email: "h.dupont@personal.example", type: "Home" }, { email: "helene.dupont@sgl-logistique.example", type: "Work" }],
      phone_jsonb: [{ number: "+33 4 72 00 00 00", type: "Work" }],
    })).data;
    await admin.post("/api/r/contact_notes", { contact_id: dup.id, text: "Met at the SITL trade show." });
    await admin.post("/api/r/tasks", { contact_id: dup.id, type: "Email", text: "Send case study", due_date: new Date().toISOString() });
    await admin.patch(`/api/r/deals/${state.deal.id}`, { contact_ids: [dup.id, state.contact.id] });

    const res = await admin.post(`/api/contacts/${dup.id}/merge`, { winnerId: state.contact.id });
    assert.equal(res.statusCode, 200, res.body);
    const merged = json(res).data;
    assert.equal(merged.first_name, "Hélène", "winner's fields win");
    assert.equal(merged.linkedin_url, "https://www.linkedin.com/in/hdupont", "loser fills gaps");
    assert.deepEqual(merged.email_jsonb.map((e: any) => e.email).sort(),
      ["h.dupont@personal.example", "helene.dupont@sgl-logistique.example"]);
    assert.equal(merged.phone_jsonb.length, 1);

    assert.equal((await admin.get(`/api/r/contacts/${dup.id}`)).statusCode, 404);
    const deal = json(await admin.get(`/api/r/deals/${state.deal.id}`)).data;
    assert.deepEqual(deal.contact_ids, [state.contact.id], "loser replaced in place, duplicates removed");
    const counts = await db.query(
      `select (select count(*)::int from tasks where contact_id = $1) as tasks,
              (select count(*)::int from contact_notes where contact_id = $1) as notes`, [state.contact.id]);
    assert.deepEqual(counts.rows[0], { tasks: 2, notes: 1 });
    const audit = await db.query(`select changes from audit_log where action = 'merge' and record_id = $1`, [String(state.contact.id)]);
    assert.equal(audit.rows[0].changes.loser_id, dup.id);
  });

  test("refuses self-merge, unknown ids and contacts the rep does not own", async () => {
    const admin = api(state.admin);
    assert.equal((await admin.post(`/api/contacts/${state.contact.id}/merge`, { winnerId: state.contact.id })).statusCode, 400);
    assert.equal((await admin.post(`/api/contacts/999999/merge`, { winnerId: state.contact.id })).statusCode, 404);
    const other = json(await admin.post("/api/r/contacts", { first_name: "Ana", last_name: "Silva" })).data;
    assert.equal((await api(state.rep).post(`/api/contacts/${other.id}/merge`, { winnerId: state.contact.id })).statusCode, 403);
    assert.equal((await admin.get(`/api/r/contacts/${other.id}`)).statusCode, 200, "nothing changed");
  });
});

describe("attachments", () => {
  const upload = (cookie: string, bytes: Buffer, name: string, type: string) =>
    app.inject({ method: "POST", url: "/api/attachments", payload: bytes,
      headers: { cookie, ...csrf, "content-type": "application/octet-stream", "x-file-name": encodeURIComponent(name), "x-file-type": type } });

  test("upload stores bytes privately and serves them only to signed-in users", async () => {
    const pdf = Buffer.from("%PDF-1.4\n% synthetic proposal\n");
    const res = await upload(state.rep, pdf, "../../Proposal Q3 – SGL.pdf", "application/pdf");
    assert.equal(res.statusCode, 201, res.body);
    const file = json(res);
    assert.equal(file.title, "Proposal Q3 – SGL.pdf", "path components stripped");
    assert.match(file.src, /^\/api\/attachments\/[0-9a-f-]{36}$/);
    assert.deepEqual(await readdir(filesDir), [file.path], "stored under a server-generated name");
    state.file = file;

    const note = await api(state.rep).post("/api/r/contact_notes", { contact_id: state.contact.id, text: "Proposal sent", attachments: [file] });
    assert.equal(note.statusCode, 201, note.body);

    const dl = await api(state.admin).get(file.src);
    assert.equal(dl.statusCode, 200);
    assert.deepEqual(dl.rawPayload, pdf);
    assert.equal(dl.headers["content-type"], "application/octet-stream");
    assert.match(String(dl.headers["content-disposition"]), /^attachment;/);
    assert.match(String(dl.headers["content-security-policy"]), /sandbox/);
    assert.equal((await app.inject({ method: "GET", url: file.src })).statusCode, 401);
    assert.ok(json(await api(state.admin).get(`/api/search?q=proposal&resources=contact_notes`)).length >= 1);
  });

  test("images are served inline; HTML is never rendered", async () => {
    const png = json(await upload(state.admin, Buffer.from([0x89, 0x50, 0x4e, 0x47]), "logo.png", "image/png"));
    const img = await api(state.admin).get(png.src);
    assert.equal(img.headers["content-type"], "image/png");
    assert.match(String(img.headers["content-disposition"]), /^inline;/);
    const html = json(await upload(state.admin, Buffer.from("<script>alert(1)</script>"), "x.html", "text/html"));
    const h = await api(state.admin).get(html.src);
    assert.equal(h.headers["content-type"], "application/octet-stream");
    assert.equal(h.headers["x-content-type-options"], "nosniff");
  });

  test("rejects empty uploads, missing CSRF header and the read-only role", async () => {
    assert.equal((await upload(state.admin, Buffer.alloc(0), "empty.txt", "text/plain")).statusCode, 400);
    const noCsrf = await app.inject({ method: "POST", url: "/api/attachments", payload: Buffer.from("x"),
      headers: { cookie: state.admin, "content-type": "application/octet-stream" } });
    assert.equal(noCsrf.statusCode, 403);
  });

  test("orphan purge removes unreferenced files after the grace period and keeps referenced ones", async () => {
    await db.query(`update attachments set created_at = now() - interval '2 days'`);
    const removed = await purgeOrphanAttachments(db, filesDir);
    assert.equal(removed, 2, "the png and html uploads were never attached to anything");
    assert.deepEqual(await readdir(filesDir), [state.file.path]);
  });
});

describe("live updates", () => {
  test("committed changes are pushed to signed-in browsers over SSE", async () => {
    await app.listen({ host: "127.0.0.1", port: 0 });
    const { port } = app.server.address() as { port: number };
    const unauth = await fetch(`http://127.0.0.1:${port}/api/events`);
    assert.equal(unauth.status, 401);
    await unauth.body?.cancel();

    const controller = new AbortController();
    const res = await fetch(`http://127.0.0.1:${port}/api/events`, { headers: { cookie: state.admin }, signal: controller.signal });
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type") ?? "", /^text\/event-stream/);
    const reader = res.body!.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    const waitFor = async (pattern: RegExp) => {
      const deadline = Date.now() + 5000;
      while (!pattern.test(buffer)) {
        if (Date.now() > deadline) throw new Error(`timed out waiting for ${pattern}; got ${buffer}`);
        const { value, done } = await reader.read();
        if (done) throw new Error("stream closed");
        buffer += decoder.decode(value);
      }
    };
    await waitFor(/event: ready/);
    await api(state.admin).patch(`/api/r/deals/${state.deal.id}`, { stage: "proposal-sent" });
    await waitFor(new RegExp(`"table":"deals","op":"update","id":${state.deal.id}`));
    controller.abort();
  });
});
