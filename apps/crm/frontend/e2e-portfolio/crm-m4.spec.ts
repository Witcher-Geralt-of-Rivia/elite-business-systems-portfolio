/**
 * M4 features in a real browser: global search, team invitation -> one-time link -> first sign-in,
 * note attachment upload/download, live updates pushed from the server, contact merge.
 * Runs against the local e2e stack (vite.portfolio-e2e.config.ts) seeded by the data engine.
 */
import { expect, test, type Page } from "@playwright/test";

const EMAIL = process.env.CRM_E2E_EMAIL ?? "";
const PASSWORD = process.env.CRM_E2E_PASSWORD ?? "";
const RUN = Date.now().toString(36);
const csrf = { "X-CRM-CSRF": "1" };

test.beforeAll(() => {
  if (!process.env.CRM_E2E_BASE_URL || !EMAIL || !PASSWORD) {
    throw new Error("CRM_E2E_BASE_URL, CRM_E2E_EMAIL and CRM_E2E_PASSWORD are required");
  }
});

async function signIn(page: Page, email = EMAIL, password = PASSWORD) {
  await page.goto("/#/login");
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(password);
  const login = page.waitForResponse((r) => r.url().endsWith("/api/auth/login"));
  await page.getByRole("button", { name: /sign in/i }).click();
  expect((await login).status()).toBe(200);
  await expect(page).not.toHaveURL(/\/login/);
}

test("global search finds generated companies and opens the record", async ({ page }) => {
  await signIn(page);
  const list = await page.request.get(`/api/r/companies?sort=id&order=ASC&start=0&end=1`);
  const company = (await list.json()).data[0];
  await page.getByRole("button", { name: "Search" }).first().click();
  const search = page.waitForResponse((r) => r.url().includes("/api/search?"));
  await page.getByPlaceholder(/Search contacts, companies/).fill(company.name);
  expect((await search).status()).toBe(200);
  // Contacts of the company also match (their subtitle is the company name): pick the company itself.
  const escaped = company.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const hit = page.getByRole("option", { name: new RegExp(`^${escaped}`) }).first();
  await expect(hit).toBeVisible();
  await hit.click();
  await expect(page).toHaveURL(new RegExp(`/companies/${company.id}`));
  await expect(page.getByText(company.name).first()).toBeVisible();
});

test("admin invites a teammate; the one-time link sets their password; they can sign in", async ({ page, browser }) => {
  await signIn(page);
  await page.goto("/#/sales/create");
  const email = `new.rep.${RUN}@meridian-advisory.example`;
  await page.locator('input[name="first_name"]').fill("Noor");
  await page.locator('input[name="last_name"]').fill(`Haddad${RUN}`);
  await page.locator('input[name="email"]').fill(email);
  const created = page.waitForResponse((r) => r.url().endsWith("/api/users") && r.request().method() === "POST");
  await page.getByRole("button", { name: /save|create/i }).first().click();
  expect((await created).status()).toBe(201);

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("Invitation link")).toBeVisible();
  const link = await dialog.getByRole("textbox", { name: "one-time link" }).inputValue();
  expect(link).toMatch(/#\/set-password\?token=/);
  await dialog.getByRole("button", { name: "Close" }).last().click();

  const invitee = await browser.newContext();
  const p2 = await invitee.newPage();
  await p2.goto(link);
  await p2.locator('input[name="password"]').fill("noor-first-passphrase-26");
  await p2.locator('input[name="confirmPassword"]').fill("noor-first-passphrase-26");
  const set = p2.waitForResponse((r) => r.url().endsWith("/api/auth/set-password"));
  await p2.getByRole("button", { name: /save/i }).click();
  expect((await set).status()).toBe(200);
  await expect(p2).toHaveURL(/\/login/);
  await signIn(p2, email, "noor-first-passphrase-26");
  const me = await p2.request.get("/api/auth/me");
  expect((await me.json()).role).toBe("sales_rep");

  // The link works only once.
  await p2.goto(link);
  await p2.locator('input[name="password"]').fill("another-passphrase-2026");
  await p2.locator('input[name="confirmPassword"]').fill("another-passphrase-2026");
  const reuse = p2.waitForResponse((r) => r.url().endsWith("/api/auth/set-password"));
  await p2.getByRole("button", { name: /save/i }).click();
  expect((await reuse).status()).toBe(400);
  await invitee.close();
});

test("a note attachment is uploaded to the API and downloads with the original bytes", async ({ page }) => {
  await signIn(page);
  const contacts = await page.request.get(`/api/r/contacts?sort=id&order=ASC&start=0&end=1`);
  const contact = (await contacts.json()).data[0];
  await page.goto(`/#/contacts/${contact.id}/show`);
  const note = `Site visit summary ${RUN}`;
  await page.locator('textarea[name="text"]').first().fill(note);
  await page.locator('input[type="file"]').first().setInputFiles({
    name: `site-visit-${RUN}.txt`,
    mimeType: "text/plain",
    buffer: Buffer.from(`Synthetic site visit report ${RUN}\n`),
  });
  const upload = page.waitForResponse((r) => r.url().endsWith("/api/attachments") && r.request().method() === "POST");
  const saved = page.waitForResponse((r) => r.url().endsWith("/api/r/contact_notes") && r.request().method() === "POST");
  await page.getByRole("button", { name: /add this note/i }).click();
  const stored = await (await upload).json();
  expect((await saved).status()).toBe(201);
  await expect(page.getByText(note)).toBeVisible();
  const download = await page.request.get(stored.src);
  expect(download.status()).toBe(200);
  expect(await download.text()).toBe(`Synthetic site visit report ${RUN}\n`);
});

test("changes made elsewhere appear without reloading (server-sent events)", async ({ page, browser }) => {
  await signIn(page);
  const contacts = await page.request.get(`/api/r/contacts?sort=id&order=ASC&start=0&end=1`);
  const contact = (await contacts.json()).data[0];
  await page.goto(`/#/contacts/${contact.id}/show`);
  await expect(page.getByText(`${contact.first_name} ${contact.last_name}`).first()).toBeVisible();

  // A teammate adds a note from another session; it must appear on this open page.
  const other = await browser.newContext({ baseURL: process.env.CRM_E2E_BASE_URL });
  const p2 = await other.newPage();
  await signIn(p2);
  const text = `Live note from a teammate ${RUN}`;
  const res = await p2.request.post("/api/r/contact_notes", { data: { contact_id: contact.id, text }, headers: csrf });
  expect(res.status()).toBe(201);
  await expect(page.getByText(text)).toBeVisible({ timeout: 15_000 });
  await other.close();
});

test("merging a duplicate contact moves its history and removes it", async ({ page }) => {
  await signIn(page);
  // A uniquely named pair, so the merge target cannot be confused with other contacts.
  const companies = await page.request.get(`/api/r/companies?sort=id&order=ASC&start=0&end=1`);
  const companyId = (await companies.json()).data[0].id;
  const person = { first_name: "Ingrid", last_name: `Merge${RUN}`, company_id: companyId };
  const winner = (await (await page.request.post("/api/r/contacts", { headers: csrf, data: { ...person, title: "VP of Operations" } })).json()).data;
  const dup = await page.request.post("/api/r/contacts", { headers: csrf, data: { ...person, title: "Duplicate entry" } });
  const loser = (await dup.json()).data;
  await page.request.post("/api/r/contact_notes", { headers: csrf, data: { contact_id: loser.id, text: `Duplicate history ${RUN}` } });

  // The merge action lives in the aside of the contact edit page.
  await page.goto(`/#/contacts/${loser.id}`);
  await page.getByRole("button", { name: /merge with another contact/i }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("combobox").first().click();
  await page.keyboard.type(winner.last_name);
  await page.getByRole("option").filter({ hasText: `${winner.first_name} ${winner.last_name}` }).first().click();
  const merged = page.waitForResponse((r) => r.url().includes(`/api/contacts/${loser.id}/merge`));
  await dialog.getByRole("button", { name: /merge/i }).last().click();
  const mergeResponse = await merged;
  expect(mergeResponse.status()).toBe(200);
  expect(JSON.parse(mergeResponse.request().postData() ?? "{}").winnerId).toBe(winner.id);
  expect((await page.request.get(`/api/r/contacts/${loser.id}`)).status()).toBe(404);
  const filter = encodeURIComponent(JSON.stringify({ contact_id: winner.id }));
  const notes = await page.request.get(`/api/r/contact_notes?filter=${filter}&start=0&end=500`);
  expect((await notes.json()).data.some((n: { text: string }) => n.text === `Duplicate history ${RUN}`)).toBe(true);
});
