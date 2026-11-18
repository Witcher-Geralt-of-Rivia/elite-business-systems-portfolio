/**
 * Read-only visitor experience on the real Harbor & Pine Market data (non-destructive):
 * demo entry without credentials, dashboards/catalog/orders/registers/reports, refused writes and
 * admin areas, checkout preview message, desktop + phone layouts, no uncaught page errors.
 */
import { devices, expect, test } from "@playwright/test";
import { apiGet, apiPost, expectNoPageErrors, trackPageErrors } from "./helpers";

const SHOTS = "test-results/pos-visitor";

async function enterDemo(page: import("@playwright/test").Page) {
  await page.goto("/sign-in");
  await page.getByRole("link", { name: /explore the live demo/i }).click();
  await page.waitForURL(/\/dashboard/, { timeout: 60_000 });
  await expect(page.locator("#hp-showcase-banner")).toBeVisible();
}

test.describe("desktop", () => {
  test("visitor enters without credentials and explores the store", async ({ page }) => {
    const errors = trackPageErrors(page);
    await enterDemo(page);
    await page.waitForTimeout(4000);
    await page.screenshot({ path: `${SHOTS}/dashboard.png` });

    await page.goto("/dashboard/products");
    await expect(page.getByText(/Morning Tide Blend/).first()).toBeVisible({ timeout: 30_000 });
    await page.screenshot({ path: `${SHOTS}/products.png` });

    await page.goto("/dashboard/orders");
    await expect(page.locator("table tbody tr").first()).toBeVisible({ timeout: 30_000 });
    await page.screenshot({ path: `${SHOTS}/orders.png` });

    await page.goto("/dashboard/cash-registers");
    await expect(page.getByText("Front Counter").first()).toBeVisible({ timeout: 30_000 });
    await page.screenshot({ path: `${SHOTS}/registers.png` });

    await page.goto("/dashboard/reports/sales");
    await page.waitForTimeout(4000);
    await page.screenshot({ path: `${SHOTS}/report-sales.png` });
    await expectNoPageErrors(errors);
  });

  test("writes, admin areas and report recomputation are refused; reads still work", async ({ page }) => {
    await enterDemo(page);
    const order = await apiPost(page, "/api/orders", { customer_id: 1, products: [], payments: [] });
    expect(order.status()).toBe(403);
    expect((await order.json()).message).toMatch(/Checkout preview/);

    for (const [url, data] of [
      ["/api/products", { name: "Visitor product" }],
      ["/api/reports/compute/day", {}],
      ["/api/cash-registers/open/1", { amount: 10 }],
      ["/api/crud/ns.products/bulk-actions", { action: "delete_selected", entries: [1] }],
    ] as const) {
      const res = await apiPost(page, url, data);
      expect(res.status(), url).toBe(403);
      expect((await res.json()).code, url).toBe("showcase_read_only");
    }
    expect((await apiGet(page.request, "/api/users")).status()).toBe(403);
    const settings = await page.goto("/dashboard/settings/general");
    expect(settings?.status()).toBe(403);

    // Read-only report POST is allowed.
    const report = await apiPost(page, "/api/reports/payment-types", { startDate: "2026-01-01 00:00:00", endDate: "2026-12-31 23:59:59" });
    expect(report.status()).toBe(200);
  });
});

// Phone viewport (browser type stays the project's Chromium).
const { defaultBrowserType: _browser, ...phone } = devices["Pixel 7"];

test.describe("mobile", () => {
  test.use(phone);

  test("visitor experience on a phone", async ({ page }) => {
    const errors = trackPageErrors(page);
    await enterDemo(page);
    await page.waitForTimeout(4000);
    await page.screenshot({ path: `${SHOTS}/mobile-dashboard.png` });
    await page.goto("/dashboard/orders");
    await page.waitForTimeout(4000);
    await page.screenshot({ path: `${SHOTS}/mobile-orders.png` });
    await expectNoPageErrors(errors);
  });
});
