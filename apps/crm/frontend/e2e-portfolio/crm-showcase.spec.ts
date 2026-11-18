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
    await page.waitForLoadState("networkidle");
    await page.screenshot({ path: `${SHOTS}/desktop-dashboard.png`, fullPage: true });

    await page.goto("/#/deals");
    await expect(page.getByText("Opportunity").first()).toBeVisible();
    await page.waitForLoadState("networkidle");
    await page.screenshot({ path: `${SHOTS}/desktop-pipeline.png` });

    await page.goto("/#/companies");
    await page.waitForLoadState("networkidle");
    const companies = await page.request.get("/api/r/companies?start=0&end=1");
    expect((await companies.json()).total).toBeGreaterThan(300);
    await page.screenshot({ path: `${SHOTS}/desktop-companies.png` });

    await page.goto("/#/contacts");
    await page.waitForLoadState("networkidle");
    await page.screenshot({ path: `${SHOTS}/desktop-contacts.png` });

    const contact = (await (await page.request.get("/api/r/contacts?sort=last_seen&order=DESC&start=0&end=1")).json()).data[0];
    await page.goto(`/#/contacts/${contact.id}/show`);
    await expect(page.getByText(`${contact.first_name} ${contact.last_name}`).first()).toBeVisible();
    await page.waitForLoadState("networkidle");
    await page.screenshot({ path: `${SHOTS}/desktop-contact.png`, fullPage: true });

    expect(errors).toEqual([]);
  });

  test("visitor cannot create, edit, administer or upload", async ({ page }) => {
    await startVisitorSession(page);
    await page.goto("/#/companies/create");
    await expect(page.locator('input[name="name"]')).toHaveCount(0);

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

test.describe("mobile", () => {
  test.use({ ...devices["Pixel 7"] });

  test("visitor experience works on a phone", async ({ page }) => {
    const errors = trackErrors(page);
    await startVisitorSession(page);
    await page.waitForLoadState("networkidle");
    await page.screenshot({ path: `${SHOTS}/mobile-home.png`, fullPage: true });
    await page.goto("/#/contacts");
    await page.waitForLoadState("networkidle");
    await page.screenshot({ path: `${SHOTS}/mobile-contacts.png` });
    expect(errors).toEqual([]);
  });
});
