import { expect, test } from "@playwright/test";
import { ADMIN_PASSWORD, call, deskRoute, expectNoErrors, login, watchErrors } from "./helpers";

/**
 * ERPNext Desk on the native-Windows installation, through the private entry point (proxy -> waitress / Socket.IO).
 * Read-only against the business data, except the draft ToDo in "forms" which the test deletes again.
 */
test.describe("ERPNext Desk (Administrator)", () => {
  test.skip(!ADMIN_PASSWORD, "ERP_E2E_ADMIN_PASSWORD not set");

  test("login, boot and assets", async ({ page }) => {
    const errors = watchErrors(page);
    await login(page, "Administrator", ADMIN_PASSWORD);
    expect(page.url()).toContain("/desk");
    const boot = await page.evaluate(() => {
      const f = (window as any).frappe;
      return { user: f.boot.user.name, apps: Object.keys(f.boot.app_data_map || {}).length || (f.boot.versions ? Object.keys(f.boot.versions) : []), versions: f.boot.versions };
    });
    expect(boot.user).toBe("Administrator");
    expect(JSON.stringify(boot.versions)).toContain("erpnext");
    // Every stylesheet and script on the page came from /assets with 200 (asset hashes match the running code).
    const assets = await page.evaluate(() =>
      [...document.querySelectorAll<HTMLScriptElement | HTMLLinkElement>("script[src], link[rel=stylesheet]")]
        .map((e) => (e as any).src || (e as any).href)
        .filter((u: string) => u.includes("/assets/")),
    );
    expect(assets.length).toBeGreaterThan(3);
    for (const url of assets) {
      const r = await page.request.get(url);
      expect(r.status(), url).toBe(200);
    }
    await expectNoErrors(errors);
  });

  test("navigation: workspaces, lists and forms of the simulated business", async ({ page }) => {
    const errors = watchErrors(page);
    await login(page, "Administrator", ADMIN_PASSWORD);

    // List views render rows from the simulated history.
    for (const doctype of ["sales-invoice", "purchase-invoice", "payment-entry", "delivery-note", "item", "customer"]) {
      await deskRoute(page, `/desk/${doctype}`);
      await expect(page.locator(".list-row-container, .list-row").first()).toBeVisible({ timeout: 60_000 });
    }

    // Open a submitted Sales Invoice form: status, customer, items table, totals and the GL connection.
    const inv = await call<any[]>(page, "frappe.client.get_list", {
      doctype: "Sales Invoice", filters: { docstatus: 1 }, fields: ["name", "customer", "grand_total"], limit_page_length: 1, order_by: "posting_date desc",
    });
    expect(inv.length).toBe(1);
    await deskRoute(page, `/desk/sales-invoice/${encodeURIComponent(inv[0].name)}`);
    await page.waitForFunction((n) => (window as any).cur_frm?.doc?.name === n, inv[0].name, { timeout: 60_000 });
    const doc = await page.evaluate(() => {
      const d = (window as any).cur_frm.doc;
      return { docstatus: d.docstatus, customer: d.customer, items: d.items.length, grand_total: d.grand_total };
    });
    expect(doc.docstatus).toBe(1);
    expect(doc.customer).toBe(inv[0].customer);
    expect(doc.items).toBeGreaterThan(0);
    expect(doc.grand_total).toBeCloseTo(inv[0].grand_total, 2);
    await expect(page.locator(".indicator-pill").first()).toBeVisible();
    await expectNoErrors(errors);
  });

  test("forms: create, save and delete a draft document", async ({ page }) => {
    const errors = watchErrors(page);
    await login(page, "Administrator", ADMIN_PASSWORD);
    await deskRoute(page, "/desk/todo/new");
    const text = `E2E check ${Date.now()}`;
    await page.waitForFunction(() => (window as any).cur_frm?.doc?.doctype === "ToDo", null, { timeout: 60_000 });
    await page.evaluate((t) => (window as any).cur_frm.set_value("description", t), text);
    await page.keyboard.press("Control+s");
    await page.waitForFunction(() => !(window as any).cur_frm.doc.__islocal, null, { timeout: 60_000 });
    const name = await page.evaluate(() => (window as any).cur_frm.doc.name);
    const saved = await call(page, "frappe.client.get_value", { doctype: "ToDo", filters: { name }, fieldname: "description" });
    expect(JSON.stringify(saved)).toContain("E2E check");
    await call(page, "frappe.client.delete", { doctype: "ToDo", name });
    await expectNoErrors(errors);
  });

  test("reports and dashboards", async ({ page }) => {
    const errors = watchErrors(page);
    await login(page, "Administrator", ADMIN_PASSWORD);

    // Script report (General Ledger) and query report (Accounts Receivable) render data rows.
    for (const report of ["General Ledger", "Accounts Receivable", "Stock Balance"]) {
      await deskRoute(page, `/desk/query-report/${encodeURIComponent(report)}`);
      await page.waitForFunction(() => (window as any).frappe.query_report?.report_name, null, { timeout: 60_000 });
      await page.waitForFunction(() => ((window as any).frappe.query_report.data || []).length > 0, null, { timeout: 90_000 });
      await expect(page.locator(".dt-row").first()).toBeVisible({ timeout: 60_000 });
    }

    // Accounting dashboard charts load from the server.
    await deskRoute(page, "/desk/accounting");
    await expect(page.locator(".widget, .workspace").first()).toBeVisible({ timeout: 60_000 });
    await expectNoErrors(errors);
  });

  test("realtime: Socket.IO connects and delivers a server event", async ({ page }) => {
    const errors = watchErrors(page);
    await login(page, "Administrator", ADMIN_PASSWORD);
    await page.waitForFunction(() => (window as any).frappe.realtime?.socket?.connected === true, null, { timeout: 60_000 });
    // A server-side publish_realtime to this user must arrive over the socket (redis pub/sub -> node -> browser).
    const got = page.evaluate(
      () =>
        new Promise<string>((resolve) => {
          (window as any).frappe.realtime.on("msgprint", (m: any) => resolve(typeof m === "string" ? m : JSON.stringify(m)));
          setTimeout(() => resolve("timeout"), 30_000);
        }),
    );
    await call(page, "portfolio_sim.health.realtime_probe");
    expect(await got).toContain("realtime probe");
    await expectNoErrors(errors);
  });
});
