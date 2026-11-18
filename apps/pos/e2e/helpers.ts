import { expect, type APIRequestContext, type Page } from "@playwright/test";

/** NexoPOS (Laravel + Sanctum) requires the XSRF token cookie echoed in a header on state-changing calls. */
export async function xsrf(page: Page): Promise<Record<string, string>> {
  const cookie = (await page.context().cookies()).find((c) => c.name === "XSRF-TOKEN");
  // Sanctum treats a request as a first-party (session) call only when Origin/Referer match a stateful domain.
  const origin = new URL(page.url()).origin;
  return {
    Origin: origin,
    Referer: `${origin}/dashboard`,
    "X-XSRF-TOKEN": cookie ? decodeURIComponent(cookie.value) : "",
    "X-Requested-With": "XMLHttpRequest",
    Accept: "application/json",
  };
}

export async function apiPost(page: Page, url: string, data: unknown) {
  return page.request.post(url, { headers: await xsrf(page), data });
}

export async function apiGet(request: APIRequestContext, url: string) {
  const origin = process.env.POS_E2E_BASE_URL ?? "http://127.0.0.1:8831";
  return request.get(url, { headers: { Accept: "application/json", "X-Requested-With": "XMLHttpRequest", Origin: origin, Referer: `${origin}/dashboard` } });
}

export async function signIn(page: Page, user: string, password: string) {
  await page.goto("/sign-in");
  await page.locator('input[name="username"]').fill(user);
  await page.locator('input[name="password"]').fill(password);
  await page.getByRole("button", { name: "Sign In" }).click();
  await page.waitForURL(/\/dashboard/, { timeout: 60_000 });
}

/**
 * POS screen: adds one unit of `item` from `category`. The grid renders before its click handlers are ready,
 * so an early category click can be lost: click until the category's products show (never again once they do).
 */
export async function addToCart(page: Page, category: string, item: string) {
  const cat = page.locator("#grid-items .cell-item", { hasText: category });
  const product = page.locator("#grid-items .cell-item", { hasText: item });
  if (!(await product.isVisible())) {
    await expect(cat).toBeVisible({ timeout: 60_000 });
    await expect(async () => {
      if (!(await product.isVisible())) await cat.click({ timeout: 5_000 }).catch(() => {});
      await expect(product).toBeVisible({ timeout: 5_000 });
    }).toPass({ timeout: 60_000 });
  }
  await product.click();
  await page.getByText("Enter", { exact: true }).click(); // quantity 1
  await expect(page.getByText(new RegExp(`${item} — Each`))).toBeVisible();
}

/**
 * POS screen: opens the payment popup. NexoPOS sometimes evaluates the order's customer before the cart has
 * settled and asks for one ("Select Customer"); the store's walk-in customer is chosen then.
 */
export async function openPayment(page: Page) {
  await page.getByText("Pay", { exact: true }).first().click();
  const payment = page.getByText("Full Payment", { exact: true });
  const customer = page.getByText("Select Customer", { exact: true });
  await expect(payment.or(customer)).toBeVisible({ timeout: 30_000 });
  if (await customer.isVisible()) {
    await page.getByText("Walk-in Customer", { exact: true }).last().click();
    const opened = await payment.waitFor({ state: "visible", timeout: 5_000 }).then(() => true, () => false);
    if (!opened) await page.getByText("Pay", { exact: true }).first().click();
    await expect(payment).toBeVisible({ timeout: 30_000 });
  }
}

export function trackPageErrors(page: Page): string[] {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  return errors;
}

export async function expectNoPageErrors(errors: string[]) {
  expect(errors, errors.join("\n")).toEqual([]);
}
