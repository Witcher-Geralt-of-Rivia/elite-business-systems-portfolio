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
    await expect(page.getByText(/^[A-Z]{3}-[A-Z]{3}-\d{4}$/).first()).toBeVisible({ timeout: 30_000 }); // catalog SKUs
    await page.screenshot({ path: `${SHOTS}/products.png` });

    await page.goto("/dashboard/orders");
    // Real rows (order codes look like 260820-048), not the "nothing to display" placeholder row.
    await expect(page.getByText(/^\d{6}-\d{3}$/).first()).toBeVisible({ timeout: 60_000 });
    await page.waitForTimeout(1000);
    await page.screenshot({ path: `${SHOTS}/orders.png` });

    await page.goto("/dashboard/customers");
    await expect(page.getByText(/@mail\.example/).first()).toBeVisible({ timeout: 60_000 });
    await page.waitForTimeout(1000);
    await page.screenshot({ path: `${SHOTS}/customers.png` });

    await page.goto("/dashboard/cash-registers");
    await expect(page.getByText("Front Counter").first()).toBeVisible({ timeout: 30_000 });
    await page.screenshot({ path: `${SHOTS}/registers.png` });

    await page.goto("/dashboard/reports/sales");
    await page.waitForTimeout(4000);
    await page.screenshot({ path: `${SHOTS}/report-sales.png` });
    await expectNoPageErrors(errors);
  });

  test("checkout preview: a full sale on the POS screen is refused with an explicit message", async ({ page }) => {
    const errors = trackPageErrors(page);
    await enterDemo(page);
    await page.goto("/dashboard/pos");
    // Visitors get the first register as a read-only preview instead of the "open a register" prompt,
    // so the product grid is usable straight away.
    await expect(page.getByText("Open The Cash Register")).toHaveCount(0);
    await page.locator("#grid-items .cell-item", { hasText: "Coffee & Tea" }).click({ timeout: 60_000 });
    await page.locator("#grid-items .cell-item", { hasText: "Morning Tide Blend — 12 oz" }).click();
    await page.getByText("Enter", { exact: true }).click(); // quantity 1
    await expect(page.getByText(/Morning Tide Blend — 12 oz — Each/)).toBeVisible();
    await page.screenshot({ path: `${SHOTS}/pos-cart.png` });

    await page.getByText("Pay", { exact: true }).first().click();
    await page.getByText("Full Payment", { exact: true }).click();
    const submitted = page.waitForResponse((r) => r.request().method() === "POST" && /\/api\/orders$/.test(r.url()));
    await page.getByRole("button", { name: "Yes", exact: true }).click(); // NexoPOS submits on full payment
    const res = await submitted;
    expect(res.status()).toBe(403);
    await expect(page.getByText(/Checkout preview: in the read-only demo this order was not saved/)).toBeVisible();
    await page.screenshot({ path: `${SHOTS}/pos-checkout-preview.png` });
    // run-pos-e2e.ps1 additionally asserts in the database that the visitor authored no orders/register entries.
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
    await expect(page.getByText(/^\d{6}-\d{3}$/).first()).toBeVisible({ timeout: 60_000 });
    await page.screenshot({ path: `${SHOTS}/mobile-orders.png` });
    await page.goto("/dashboard/pos");
    await page.waitForTimeout(8000);
    await page.screenshot({ path: `${SHOTS}/mobile-pos.png` });
    await expectNoPageErrors(errors);
  });
});
