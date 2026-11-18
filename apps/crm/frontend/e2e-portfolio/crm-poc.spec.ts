/**
 * PoC acceptance in a real browser against the deployed stack:
 * Atomic CRM UI -> Caddy (HTTPS) -> portfolio API -> PostgreSQL.
 */
import { expect, test, type Page } from "@playwright/test";

const EMAIL = process.env.CRM_E2E_EMAIL ?? "";
const PASSWORD = process.env.CRM_E2E_PASSWORD ?? "";
const COMPANY = `Halvorsen Maritime Analytics ${Date.now().toString(36)}`;

test.beforeAll(() => {
  if (!process.env.CRM_E2E_BASE_URL || !EMAIL || !PASSWORD) {
    throw new Error("CRM_E2E_BASE_URL, CRM_E2E_EMAIL and CRM_E2E_PASSWORD are required");
  }
});

async function signIn(page: Page, password = PASSWORD) {
  await page.goto("/");
  await expect(page).toHaveURL(/\/login/);
  await page.locator('input[type="email"]').fill(EMAIL);
  await page.locator('input[type="password"]').fill(password);
  await page.getByRole("button", { name: /sign in/i }).click();
}

test("wrong password is refused and stays on the login page", async ({ page }) => {
  const response = page.waitForResponse((r) => r.url().endsWith("/api/auth/login"));
  await signIn(page, "definitely-not-the-password");
  expect((await response).status()).toBe(401);
  await expect(page).toHaveURL(/\/login/);
});

test("sign in, create a company through the UI, verify persistence, clean up, sign out", async ({ page }) => {
  // --- authentication
  const login = page.waitForResponse((r) => r.url().endsWith("/api/auth/login"));
  await signIn(page);
  expect((await login).status()).toBe(200);
  await expect(page).not.toHaveURL(/\/login/);
  await expect(page.getByRole("link", { name: "Companies" }).first()).toBeVisible();

  const cookies = await page.context().cookies();
  const session = cookies.find((c) => c.name === "crm_session");
  expect(session?.httpOnly).toBe(true);
  expect(session?.secure).toBe(true);

  // --- create through the real form
  await page.goto("/#/companies/create");
  await page.locator('input[name="name"]').fill(COMPANY);
  await page.locator('input[name="city"]').fill("Bergen");
  const created = page.waitForResponse((r) => r.url().endsWith("/api/r/companies") && r.request().method() === "POST");
  await page.getByRole("button", { name: "Create Company" }).click();
  const createdResponse = await created;
  expect(createdResponse.status()).toBe(201);
  const { data } = await createdResponse.json();
  await expect(page.getByText(COMPANY).first()).toBeVisible();

  // --- persisted: fresh read through the API (same session) and visible in the list
  const check = await page.request.get(
    `/api/r/companies?filter=${encodeURIComponent(JSON.stringify({ name: COMPANY }))}`,
  );
  expect(check.status()).toBe(200);
  expect((await check.json()).total).toBe(1);
  // The CRM holds hundreds of companies: find the new one through the list's search filter.
  await page.goto(`/#/companies?filter=${encodeURIComponent(JSON.stringify({ q: COMPANY }))}`);
  await page.reload();
  await expect(page.getByText(COMPANY).first()).toBeVisible();

  // --- update through the API and see it in the UI
  const patched = await page.request.patch(`/api/r/companies/${data.id}`, {
    headers: { "X-CRM-CSRF": "1" },
    data: { city: "Stavanger" },
  });
  expect(patched.status()).toBe(200);
  await page.goto(`/#/companies/${data.id}/show`);
  await expect(page.getByText("Stavanger").first()).toBeVisible();

  // --- clean up and sign out
  const removed = await page.request.delete(`/api/r/companies/${data.id}`, { headers: { "X-CRM-CSRF": "1" } });
  expect(removed.status()).toBe(200);
  const logout = await page.request.post("/api/auth/logout", { headers: { "X-CRM-CSRF": "1" }, data: {} });
  expect(logout.status()).toBe(200);
  await page.goto("/#/companies");
  await expect(page).toHaveURL(/\/login/);
});
