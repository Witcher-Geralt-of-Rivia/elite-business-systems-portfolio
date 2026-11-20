import { expect, test } from "@playwright/test";
import { call, deskRoute, login, VIEWER_PASSWORD, VIEWER_USER } from "./helpers";

/**
 * Role-based permissions through the browser: a user with only the "Sales User" role (created by the runner) can work
 * with sales documents but is refused purchasing, accounting setup and user administration - by the server, not
 * just hidden in the UI.
 */
test.describe("ERPNext permissions (Sales User)", () => {
  test.skip(!VIEWER_PASSWORD, "ERP_E2E_VIEWER_PASSWORD not set");

  test("sales documents allowed, purchasing and administration refused", async ({ page }) => {
    await login(page, VIEWER_USER, VIEWER_PASSWORD);
    const roles = await page.evaluate(() => (window as any).frappe.user_roles as string[]);
    expect(roles).toContain("Sales User");
    expect(roles).not.toContain("System Manager");

    // Allowed: read sales orders and customers.
    const orders = await call<any[]>(page, "frappe.client.get_list", { doctype: "Sales Order", fields: ["name"], limit_page_length: 3 });
    expect(orders.length).toBeGreaterThan(0);
    await deskRoute(page, "/desk/sales-order");
    await expect(page.locator(".list-row-container, .list-row").first()).toBeVisible({ timeout: 60_000 });

    // Users: Frappe lets everyone query the User list, filtered to what they may see - here only themselves.
    const users = await call<any[]>(page, "frappe.client.get_list", { doctype: "User", fields: ["name"], limit_page_length: 50 });
    expect(users.map((u) => u.name)).toEqual([VIEWER_USER]);

    // Refused by the server: purchasing, the general ledger, administration.
    // Settings (a single-record doctype) through the document API.
    const settings = await page.evaluate(async () =>
      (await fetch("/api/method/frappe.client.get?doctype=System%20Settings&name=System%20Settings", { headers: { Accept: "application/json" } })).status);
    expect(settings, "System Settings").toBe(403);
    for (const doctype of ["Purchase Invoice", "GL Entry", "Error Log", "Scheduled Job Type"]) {
      const status = await page.evaluate(async (dt) => {
        const r = await fetch(`/api/resource/${encodeURIComponent(dt)}?limit_page_length=1`, { headers: { Accept: "application/json" } });
        return r.status;
      }, doctype);
      expect(status, doctype).toBe(403);
    }

    // The Desk shows the refusal for a forbidden list instead of data.
    await page.goto("/desk/purchase-invoice");
    await expect(page.getByText(/not permitted|insufficient permission|no permission/i).first()).toBeVisible({ timeout: 60_000 });
  });

  test("guest gets no data", async ({ request }) => {
    const r = await request.get("/api/resource/Sales Invoice?limit_page_length=1");
    expect([401, 403]).toContain(r.status());
    const h = await request.get("/api/method/portfolio_sim.health.status");
    const body = JSON.stringify(await h.json());
    expect(body).not.toMatch(/password|127\.0\.0\.1|db_name|Sales Invoice/i);
  });
});
