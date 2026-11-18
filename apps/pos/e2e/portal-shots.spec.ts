/**
 * Portfolio portal screenshot (read-only visitor, real data): the POS checkout screen with a small cart.
 * Nothing is submitted — the cart lives in the browser only. Run with:
 *   scripts/verification/run-pos-e2e.ps1 -Mode visitor -Spec portal-shots.spec.ts
 * Output: test-results/portal/pos.png (1280 × 800), converted for portal/site/assets/shots/.
 */
import { expect, test } from "@playwright/test";

test.use({ viewport: { width: 1280, height: 800 } });

test("POS checkout screen for the portal", async ({ page }) => {
  await page.goto("/sign-in");
  await page.getByRole("link", { name: /explore the live demo/i }).click();
  await page.waitForURL(/\/dashboard/, { timeout: 60_000 });
  await page.goto("/dashboard/pos");
  await page.locator("#grid-items .cell-item", { hasText: "Coffee & Tea" }).click({ timeout: 60_000 });
  for (const item of ["Morning Tide Blend — 12 oz", "Lighthouse Espresso — 12 oz"]) {
    await page.locator("#grid-items .cell-item", { hasText: item }).click();
    await page.getByText("Enter", { exact: true }).click(); // quantity 1
    await expect(page.getByText(new RegExp(`${item} — Each`))).toBeVisible();
  }
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(1500); // product artwork
  await page.screenshot({ path: "test-results/portal/pos.png" });
});
