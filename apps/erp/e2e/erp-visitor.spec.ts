import { expect, test } from "@playwright/test";
import { call, deskRoute } from "./helpers";

/**
 * Credential-free, read-only visitor access (portfolio_sim.visitor). Runs only when the runner has switched the
 * site's `portfolio_visitor_enabled` flag on for the test (ERP_E2E_VISITOR=1); the flag is off in normal operation.
 * Every write attempt must be refused by the server, whatever the UI shows.
 */
const VISITOR = "visitor@sableridge.example";

test.describe("ERPNext read-only visitor", () => {
  test.skip(process.env.ERP_E2E_VISITOR !== "1", "visitor access not enabled for this run");

  test("enter without credentials, browse the business, every write refused", async ({ page }) => {
    await page.goto("/api/method/portfolio_sim.visitor.enter");
    await page.waitForURL(/\/desk/, { timeout: 60_000 });
    await page.waitForFunction(() => (window as any).frappe?.boot?.user?.name, null, { timeout: 60_000 });
    const roles = await page.evaluate(() => (window as any).frappe.user_roles as string[]);
    expect(await page.evaluate(() => (window as any).frappe.session.user)).toBe(VISITOR);
    expect(roles).toContain("Portfolio Visitor");
    expect(roles).not.toContain("System Manager");
    expect(roles).not.toContain("Accounts Manager");

    // Read: lists, a submitted invoice, a report.
    for (const [route, doctype] of [["sales-invoice", "Sales Invoice"], ["purchase-order", "Purchase Order"], ["item", "Item"], ["customer", "Customer"]]) {
      await deskRoute(page, `/desk/${route}`);
      await page.waitForFunction((dt) => (window as any).cur_list?.doctype === dt, doctype, { timeout: 60_000 });
    }
    const inv = await call<any[]>(page, "frappe.client.get_list", { doctype: "Sales Invoice", filters: { docstatus: 1 }, fields: ["name"], limit_page_length: 1 });
    expect(inv.length).toBe(1);
    await deskRoute(page, `/desk/sales-invoice/${encodeURIComponent(inv[0].name)}`);
    await page.waitForFunction((n) => (window as any).cur_frm?.doc?.name === n, inv[0].name, { timeout: 60_000 });
    expect(await page.evaluate(() => (window as any).cur_frm.perm[0].write ? 1 : 0)).toBe(0);
    expect(await page.evaluate(() => (window as any).cur_frm.perm[0].cancel ? 1 : 0)).toBe(0);

    // Write attempts through the API are refused by the server (403) - documents, settings and the visitor's own user.
    const attempts: Array<[string, Record<string, unknown>]> = [
      ["frappe.client.insert", { doc: { doctype: "Customer", customer_name: "E2E Visitor Should Fail", customer_type: "Company" } }],
      ["frappe.client.insert", { doc: { doctype: "ToDo", description: "visitor write" } }],
      ["frappe.client.set_value", { doctype: "Sales Invoice", name: inv[0].name, fieldname: "remarks", value: "visitor edit" }],
      ["frappe.client.cancel", { doctype: "Sales Invoice", name: inv[0].name }],
      ["frappe.client.delete", { doctype: "Sales Invoice", name: inv[0].name }],
      ["frappe.client.set_value", { doctype: "User", name: VISITOR, fieldname: "first_name", value: "Hacked" }],
    ];
    for (const [method, args] of attempts) {
      const status = await page.evaluate(async ({ method, args }) => {
        const r = await fetch(`/api/method/${method}`, {
          method: "POST",
          headers: { "Content-Type": "application/json", Accept: "application/json", "X-Frappe-CSRF-Token": (window as any).frappe.csrf_token },
          body: JSON.stringify(args),
        });
        return r.status;
      }, { method, args });
      expect(status, `${method} ${JSON.stringify(args).slice(0, 60)}`).toBe(403);
    }
    // Nothing was written.
    expect(await call<number>(page, "frappe.client.get_count", { doctype: "Customer", filters: { customer_name: "E2E Visitor Should Fail" } })).toBe(0);
    // Administration stays closed.
    const userList = await page.evaluate(async () => (await fetch("/api/resource/Error Log?limit_page_length=1")).status);
    expect(userList).toBe(403);
  });
});
