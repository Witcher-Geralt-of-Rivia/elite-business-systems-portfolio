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

    // List views render the simulated history: the list's record count equals the server's count, and documents
    // that exist show rows. Sales documents, items and customers must exist at any point of the history.
    const lists: Array<[string, string, boolean]> = [
      ["sales-order", "Sales Order", true], ["delivery-note", "Delivery Note", true], ["sales-invoice", "Sales Invoice", true],
      ["item", "Item", true], ["customer", "Customer", true], ["purchase-order", "Purchase Order", false],
      ["purchase-invoice", "Purchase Invoice", false], ["payment-entry", "Payment Entry", false], ["stock-entry", "Stock Entry", false],
    ];
    for (const [route, doctype, required] of lists) {
      const count = await call<number>(page, "frappe.client.get_count", { doctype });
      if (required) expect(count, doctype).toBeGreaterThan(0);
      await deskRoute(page, `/desk/${route}`);
      await page.waitForFunction((dt) => (window as any).cur_list?.doctype === dt, doctype, { timeout: 60_000 });
      if (count > 0) {
        await page.waitForFunction(() => ((window as any).cur_list?.data || []).length > 0, null, { timeout: 60_000 });
        await expect(page.locator(".list-row-container, .list-row").first()).toBeVisible({ timeout: 60_000 });
      }
      const [shown, pageLength] = await page.evaluate(() => [(window as any).cur_list.data.length, (window as any).cur_list.page_length]);
      expect(shown, `${doctype} rows shown`).toBe(Math.min(count, pageLength));
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
    // The form shows the document's status (Unpaid / Overdue / Paid / ... as computed by ERPNext).
    const status = await page.evaluate(() => (window as any).cur_frm.doc.status);
    expect(status).toBeTruthy();
    await expect(page.getByText(status, { exact: true }).first()).toBeVisible();
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
    test.setTimeout(420_000);
    const errors = watchErrors(page);
    await login(page, "Administrator", ADMIN_PASSWORD);

    // Reports over the simulated period (the defaults cover the current month, outside the simulated history).
    const company = await call<string>(page, "frappe.client.get_value", { doctype: "Company", filters: {}, fieldname: "name" }).then((r: any) => r.name);
    const edge = async (order: string) =>
      (await call<any[]>(page, "frappe.client.get_list", { doctype: "GL Entry", fields: ["posting_date"], order_by: `posting_date ${order}`, limit_page_length: 1 }))[0].posting_date;
    const range = { from_date: await edge("asc"), to_date: await edge("desc") };
    const reports: Array<[string, Record<string, unknown>]> = [
      ["General Ledger", { company, ...range, group_by: "Group by Voucher (Consolidated)" }],
      ["Accounts Receivable", { company, report_date: range.to_date }],
      ["Stock Balance", { company, ...range }],
      ["Sales Analytics", { company, ...range, range: "Weekly" }],
    ];
    for (const [report, filters] of reports) {
      const t0 = Date.now();
      // Filters as URL parameters (route options), the way Desk links open reports.
      const qs = new URLSearchParams(Object.entries(filters).map(([k, v]) => [k, String(v)])).toString();
      await deskRoute(page, `/desk/query-report/${encodeURIComponent(report)}?${qs}`);
      await page.waitForFunction((r) => (window as any).frappe.query_report?.report_name === r, report, { timeout: 60_000 });
      if (await page.evaluate(() => !!(window as any).frappe.query_report.prepared_report)) {
        // Prepared report (e.g. Stock Balance): generated by a background worker; the page is told over Socket.IO
        // when the job finishes and then loads the result.
        // The button reads "Generate New Report" (first time) or "Rebuild" (a result for these filters exists).
        const done = () => call<number>(page, "frappe.client.get_count", { doctype: "Prepared Report", filters: { report_name: report, status: "Completed" } });
        const before = await done();
        await page.getByRole("button", { name: /^(Generate New Report|Rebuild)$/ }).first().click();
        await expect.poll(done, { timeout: 240_000, intervals: [3_000] }).toBeGreaterThan(before);
        await page.waitForFunction(() => ((window as any).frappe.query_report.data || []).length > 0, null, { timeout: 120_000 });
      }
      await page.waitForFunction(() => ((window as any).frappe.query_report.data || []).length > 0, null, { timeout: 90_000 });
      const applied = await page.evaluate(() => (window as any).frappe.query_report.get_filter_values?.() ?? {});
      expect(applied.company, `${report} company filter`).toBe(company);
      await expect(page.locator(".dt-row").first()).toBeVisible({ timeout: 60_000 });
      const rows = await page.evaluate(() => (window as any).frappe.query_report.data.length);
      console.log(`report ${report}: ${rows} rows in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
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
