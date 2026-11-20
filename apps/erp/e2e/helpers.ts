import { expect, type Page } from "@playwright/test";

export const ADMIN_PASSWORD = process.env.ERP_E2E_ADMIN_PASSWORD ?? "";
export const VIEWER_USER = process.env.ERP_E2E_VIEWER_USER ?? "e2e.viewer@sableridge.example";
export const VIEWER_PASSWORD = process.env.ERP_E2E_VIEWER_PASSWORD ?? "";

/** Collects page errors and failed same-origin requests so every spec can assert a clean console. */
export function watchErrors(page: Page) {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
  page.on("response", (r) => {
    const url = r.url();
    if (r.status() >= 500 && url.startsWith(new URL(page.url() || "http://127.0.0.1").origin)) errors.push(`${r.status()} ${url}`);
    if (r.status() === 404 && url.includes("/assets/")) errors.push(`404 ${url}`);
  });
  return errors;
}

export async function login(page: Page, user: string, password: string) {
  await page.goto("/login");
  await page.locator("#login_email").fill(user);
  await page.locator("#login_password").fill(password);
  await Promise.all([
    page.waitForURL((u) => !u.pathname.startsWith("/login"), { timeout: 60_000 }),
    page.locator("#login_password").press("Enter"),
  ]);
  // Desk boot finished: the frappe client object and its boot info exist.
  await page.waitForFunction(() => (window as any).frappe?.boot?.user?.name, null, { timeout: 60_000 });
}

/** Waits until the Desk router has rendered the page for `route` (frappe.get_route()). */
export async function deskRoute(page: Page, path: string) {
  await page.goto(path);
  await page.waitForFunction(() => (window as any).frappe?.router && (window as any).cur_page, null, { timeout: 60_000 });
}

export async function call<T = any>(page: Page, method: string, args: Record<string, unknown> = {}): Promise<T> {
  return page.evaluate(
    async ({ method, args }) => {
      const r = await (window as any).frappe.call({ method, args });
      return r.message;
    },
    { method, args },
  );
}

export async function expectNoErrors(errors: string[]) {
  expect(errors, errors.join("\n")).toEqual([]);
}
