import { expect, type APIRequestContext, type Page } from "@playwright/test";

/** NexoPOS (Laravel + Sanctum) requires the XSRF token cookie echoed in a header on state-changing calls. */
export async function xsrf(page: Page): Promise<Record<string, string>> {
  const cookie = (await page.context().cookies()).find((c) => c.name === "XSRF-TOKEN");
  return {
    "X-XSRF-TOKEN": cookie ? decodeURIComponent(cookie.value) : "",
    "X-Requested-With": "XMLHttpRequest",
    Accept: "application/json",
  };
}

export async function apiPost(page: Page, url: string, data: unknown) {
  return page.request.post(url, { headers: await xsrf(page), data });
}

export async function apiGet(request: APIRequestContext, url: string) {
  return request.get(url, { headers: { Accept: "application/json", "X-Requested-With": "XMLHttpRequest" } });
}

export async function signIn(page: Page, user: string, password: string) {
  await page.goto("/sign-in");
  await page.locator('input[name="username"]').fill(user);
  await page.locator('input[name="password"]').fill(password);
  await page.getByRole("button", { name: "Sign In" }).click();
  await page.waitForURL(/\/dashboard/, { timeout: 60_000 });
}

export function trackPageErrors(page: Page): string[] {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  return errors;
}

export async function expectNoPageErrors(errors: string[]) {
  expect(errors, errors.join("\n")).toEqual([]);
}
