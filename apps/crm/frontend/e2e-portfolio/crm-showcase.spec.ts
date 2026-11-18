/**
 * Visitor experience on the public deployment: read-only showcase session (no credentials),
 * main screens on desktop and mobile, refusal of writes, no uncaught page errors.
 * Screenshots are written to test-results/showcase/ for the acceptance review.
 */
import { devices, expect, test, type Page } from "@playwright/test";

const SHOTS = "test-results/showcase";

function trackErrors(page: Page) {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  return errors;
}

async function startVisitorSession(page: Page) {
  await page.goto("/#/login");
  const start = page.waitForResponse((r) => r.url().endsWith("/api/auth/showcase"));
  await page.getByRole("button", { name: /explore the live demo/i }).click();
  expect((await start).status()).toBe(200);
  await expect(page).not.toHaveURL(/\/login/);
  await expect(page.getByText(/read-only demo/i)).toBeVisible();
}

test.describe("desktop", () => {
  test("visitor explores dashboard, pipeline, companies, contacts and tasks", async ({ page }) => {
    const errors = trackErrors(page);
    await startVisitorSession(page);
    // The dashboard must render real data, not just a shell.
    await expect(page.getByText("Upcoming Deal Revenue")).toBeVisible({ timeout: 20_000 });
    await expect(page.getByText("Latest Activity")).toBeVisible();
    await expect(page.locator("text=/added|moved|note about/").first()).toBeVisible();
    await page.screenshot({ path: `${SHOTS}/desktop-dashboard.png` });

    await page.goto("/#/deals");
    await expect(page.getByText("Opportunity").first()).toBeVisible();
    await page.waitForLoadState("networkidle");
    await page.screenshot({ path: `${SHOTS}/desktop-pipeline.png` });

    await page.goto("/#/companies");
    const firstCompany = (await (await page.request.get("/api/r/companies?sort=name&order=ASC&start=0&end=1")).json()).data[0];
    await expect(page.getByText(firstCompany.name).first()).toBeVisible({ timeout: 20_000 });
    const companies = await page.request.get("/api/r/companies?start=0&end=1");
    expect((await companies.json()).total).toBeGreaterThan(300);
    await page.screenshot({ path: `${SHOTS}/desktop-companies.png` });

    await page.goto("/#/contacts");
    const firstContact = (await (await page.request.get("/api/r/contacts?sort=last_seen&order=DESC&start=0&end=1")).json()).data[0];
    await expect(page.getByText(`${firstContact.first_name} ${firstContact.last_name}`).first()).toBeVisible({ timeout: 20_000 });
    await page.screenshot({ path: `${SHOTS}/desktop-contacts.png` });

    const contact = (await (await page.request.get("/api/r/contacts?sort=last_seen&order=DESC&start=0&end=1")).json()).data[0];
    await page.goto(`/#/contacts/${contact.id}/show`);
    await expect(page.getByText(`${contact.first_name} ${contact.last_name}`).first()).toBeVisible({ timeout: 20_000 });
    // Notes are part of the record page: wait for the newest one to render.
    const notesFilter = encodeURIComponent(JSON.stringify({ contact_id: contact.id }));
    const note = (await (await page.request.get(`/api/r/contact_notes?filter=${notesFilter}&sort=date&order=DESC&start=0&end=1`)).json()).data[0];
    if (note) await expect(page.getByText(note.text.slice(0, 40)).first()).toBeVisible({ timeout: 20_000 });
    await page.screenshot({ path: `${SHOTS}/desktop-contact.png` });

    expect(errors).toEqual([]);
  });

  test("visitor cannot create, edit, administer or upload", async ({ page }) => {
    await startVisitorSession(page);
    // Trying anyway through the UI: the save is refused with a clear message and nothing is stored.
    const name = `Visitor attempt ${Date.now().toString(36)}`;
    await page.goto("/#/companies/create");
    await page.locator('input[name="name"]').fill(name);
    const save = page.waitForResponse((r) => r.url().endsWith("/api/r/companies") && r.request().method() === "POST");
    await page.getByRole("button", { name: "Create Company" }).click();
    expect((await save).status()).toBe(403);
    await expect(page.getByText(/read-only demo: changes are disabled/i).first()).toBeVisible();
    const filter = encodeURIComponent(JSON.stringify({ name }));
    expect((await (await page.request.get(`/api/r/companies?filter=${filter}`)).json()).total).toBe(0);

    const headers = { "X-CRM-CSRF": "1" };
    const attempts = [
      await page.request.post("/api/r/companies", { headers, data: { name: "Visitor Inc" } }),
      await page.request.post("/api/users", { headers, data: { email: "v@example.com", first_name: "V", last_name: "V" } }),
      await page.request.put("/api/configuration", { headers, data: { title: "Hacked" } }),
      await page.request.post("/api/attachments", { headers: { ...headers, "Content-Type": "application/octet-stream" }, data: Buffer.from("x") }),
    ];
    for (const res of attempts) {
      expect(res.status()).toBe(403);
      expect((await res.json()).code).toBe("showcase_read_only");
    }
    const signup = await page.request.post("/api/auth/signup", {
      headers,
      data: { email: "late@example.com", password: "a-long-enough-password", first_name: "L", last_name: "C" },
    });
    expect(signup.status()).toBe(403);
  });
});

// Phone viewport/touch/user agent (the browser type stays the project's Chromium).
const { defaultBrowserType: _browser, ...phone } = devices["Pixel 7"];

test.describe("mobile", () => {
  test.use(phone);

  test("visitor experience works on a phone", async ({ page }) => {
    const errors = trackErrors(page);
    await startVisitorSession(page);
    await expect(page.locator("text=/added|moved|note about/").first()).toBeVisible({ timeout: 20_000 });
    await page.screenshot({ path: `${SHOTS}/mobile-home.png` });
    await page.goto("/#/contacts");
    const c = (await (await page.request.get("/api/r/contacts?sort=last_seen&order=DESC&start=0&end=1")).json()).data[0];
    await expect(page.getByText(`${c.first_name} ${c.last_name}`).first()).toBeVisible({ timeout: 20_000 });
    await page.screenshot({ path: `${SHOTS}/mobile-contacts.png` });
    expect(errors).toEqual([]);
  });
});
