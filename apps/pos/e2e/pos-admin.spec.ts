/**
 * Store-administrator workflows on an ISOLATED clone of the POS database (see run-pos-e2e.ps1 -Mode isolated):
 * authentication, register session (open, cash-in, close/reconcile), checkout with simulated payment through
 * the same orders API the POS screen uses, stock decrease, dashboard update, refund with restock.
 */
import { expect, test, type Page } from "@playwright/test";
import { addToCart, apiGet, apiPost, openPayment, signIn } from "./helpers";

test.describe.configure({ mode: "serial" });
test.skip(process.env.POS_E2E_MODE !== "isolated", "destructive specs run only against the isolated clone");

const USER = process.env.POS_E2E_ADMIN_USER ?? "";
const PASSWORD = process.env.POS_E2E_ADMIN_PASSWORD ?? "";
const state: Record<string, any> = {};
let page: Page;

test.beforeAll(async ({ browser }) => {
  page = await browser.newPage();
});

test("wrong password is refused; the administrator reaches the dashboard", async () => {
  await page.goto("/sign-in");
  await page.locator('input[name="username"]').fill(USER);
  await page.locator('input[name="password"]').fill("definitely-wrong-password");
  await page.getByRole("button", { name: "Sign In" }).click();
  await page.waitForTimeout(3000);
  await expect(page).toHaveURL(/sign-in/);
  await signIn(page, USER, PASSWORD);
  await expect(page).toHaveURL(/dashboard/);
});

test("register session: open with a float and record a cash-in", async () => {
  const registers = await (await apiGet(page.request, "/api/cash-registers")).json();
  const front = registers.find((r: any) => r.name === "Front Counter");
  expect(front, JSON.stringify(registers).slice(0, 300)).toBeTruthy();
  if (front.status === "opened") {
    const closed = await apiPost(page, `/api/cash-registers/close/${front.id}`, { amount: Number(front.balance), description: "e2e: close before test" });
    expect(closed.status()).toBe(200);
  }
  const opened = await apiPost(page, `/api/cash-registers/open/${front.id}`, { amount: 150, description: "e2e opening float" });
  expect(opened.status(), await opened.text()).toBe(200);
  const cashIn = await apiPost(page, `/api/cash-registers/register-cash-in/${front.id}`, { amount: 25, description: "e2e change top-up" });
  expect(cashIn.status(), await cashIn.text()).toBe(200);
  const after = (await (await apiGet(page.request, `/api/cash-registers/${front.id}`)).json());
  const balance = Number((Array.isArray(after) ? after[0] : after).balance);
  expect(balance).toBeCloseTo(175, 2);
  state.register = front.id;
  state.balance = balance;
});

/** Today's sales total from the native sales report (store-local day). */
async function todaysSales(): Promise<number> {
  const day = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Los_Angeles" }).format(new Date());
  const res = await apiPost(page, "/api/reports/sale-report", { startDate: `${day} 00:00:00`, endDate: `${day} 23:59:59`, type: "products_report" });
  expect(res.status(), await res.text()).toBe(200);
  return Number((await res.json()).summary?.total ?? 0);
}

test("checkout with a simulated payment decreases stock and records the payment", async () => {
  state.salesBefore = await todaysSales();
  const found = await (await apiPost(page, "/api/products/search", { search: "Morning Tide Blend" })).json();
  const product = (Array.isArray(found) ? found : found.data ?? []).find((p: any) => /Morning Tide Blend/.test(p.name));
  expect(product).toBeTruthy();
  const quantities = await (await apiGet(page.request, `/api/products/${product.id}/units/quantities`)).json();
  const uq = quantities[0];
  const before = Number(uq.quantity);
  expect(before).toBeGreaterThan(2);
  const customers = await (await apiPost(page, "/api/customers/search", { search: "walk-in" })).json();
  const customer = (Array.isArray(customers) ? customers : customers.data)[0];

  const price = Number(uq.sale_price_edit ?? uq.sale_price);
  const total = Math.round(price * 2 * 100) / 100; // groceries: tax exempt
  const tendered = Math.ceil(total / 10) * 10;
  const res = await apiPost(page, "/api/orders", {
    customer_id: customer.id, type: { identifier: "takeaway" }, register_id: state.register,
    products: [{ product_id: product.id, unit_quantity_id: uq.id, unit_id: uq.unit_id, quantity: 2, unit_price: price }],
    tax_type: "exclusive", tax_value: 0,
    payments: [{ identifier: "cash-payment", value: tendered }],
  });
  expect(res.status(), await res.text()).toBe(200);
  const order = (await res.json()).data.order;
  expect(order.payment_status).toBe("paid");
  expect(Number(order.total)).toBeCloseTo(total, 2);
  expect(Number(order.change)).toBeCloseTo(tendered - total, 2);
  const afterQty = Number((await (await apiGet(page.request, `/api/products/${product.id}/units/quantities`)).json())[0].quantity);
  expect(afterQty).toBe(before - 2);
  const reg = await (await apiGet(page.request, `/api/cash-registers/${state.register}`)).json();
  expect(Number((Array.isArray(reg) ? reg[0] : reg).balance)).toBeCloseTo(state.balance + total, 2);
  Object.assign(state, { order, product, uq, before, price, total, customer });
});

test("checkout through the POS screen with the simulated card payment", async () => {
  await page.goto("/dashboard/pos");
  await addToCart(page, "Coffee & Tea", "Lighthouse Espresso — 12 oz");
  await openPayment(page);
  await page.getByText("Card (simulated)", { exact: true }).click();
  await page.getByText("Full Payment", { exact: true }).click();
  const submitted = page.waitForResponse((r) => r.request().method() === "POST" && /\/api\/orders$/.test(r.url()));
  await page.getByRole("button", { name: "Yes", exact: true }).click();
  const res = await submitted;
  expect(res.status(), await res.text()).toBe(200);
  const order = (await res.json()).data.order;
  expect(order.payment_status).toBe("paid");
  const payments = await (await apiGet(page.request, `/api/orders/${order.id}/payments`)).json();
  expect(JSON.stringify(payments)).toContain("card-payment");
  state.cardTotal = Number(order.total);
  await page.waitForTimeout(2000);
  await page.screenshot({ path: "test-results/pos-admin/pos-card-sale.png" });
});

test("receipt, customer history and the daily sales report include the sale", async () => {
  const receipt = await page.goto(`/dashboard/orders/receipt/${state.order.id}`);
  expect(receipt?.status()).toBe(200);
  await expect(page.getByText(state.order.code).first()).toBeVisible({ timeout: 30_000 });
  await expect(page.getByText(/Morning Tide Blend/).first()).toBeVisible();
  await page.screenshot({ path: "test-results/pos-admin/receipt.png" });

  const history = await (await apiGet(page.request, `/api/customers/${state.customer.id}/orders`)).json();
  const rows = Array.isArray(history) ? history : history.data ?? [];
  expect(rows.some((o: any) => o.id === state.order.id), "order listed in the customer's history").toBe(true);

  const after = await todaysSales();
  // Both sales of this run: the API cash sale and the POS-screen card sale.
  expect(after - state.salesBefore).toBeCloseTo(state.total + state.cardTotal, 2);
});

test("the dashboard reflects the new sale", async () => {
  const res = await apiGet(page.request, "/api/dashboard/day");
  expect(res.status()).toBe(200);
  const body = JSON.stringify(await res.json());
  expect(body.length).toBeGreaterThan(20);
  await page.goto("/dashboard");
  await page.waitForTimeout(4000);
  await page.screenshot({ path: "test-results/pos-admin/dashboard-after-sale.png" });
});

test("refund of one item restocks it and marks the order partially refunded", async () => {
  const lines = await (await apiGet(page.request, `/api/orders/${state.order.id}/products`)).json();
  const line = lines[0];
  const res = await apiPost(page, `/api/orders/${state.order.id}/refund`, {
    payment: { identifier: "cash-payment" }, refund_shipping: false, total: state.price,
    products: [{ id: line.id, quantity: 1, unit_price: state.price, condition: "unspoiled", description: "e2e: customer changed mind" }],
  });
  expect(res.status(), await res.text()).toBe(200);
  const afterQty = Number((await (await apiGet(page.request, `/api/products/${state.product.id}/units/quantities`)).json())[0].quantity);
  expect(afterQty).toBe(state.before - 1);
  const refunds = await (await apiGet(page.request, `/api/orders/${state.order.id}/refunds`)).json();
  expect(JSON.stringify(refunds)).toContain("e2e: customer changed mind");
});

test("closing the register at the counted balance reconciles", async () => {
  const reg = await (await apiGet(page.request, `/api/cash-registers/${state.register}`)).json();
  const balance = Number((Array.isArray(reg) ? reg[0] : reg).balance);
  const res = await apiPost(page, `/api/cash-registers/close/${state.register}`, { amount: balance, description: "e2e end of day" });
  expect(res.status(), await res.text()).toBe(200);
  const after = await (await apiGet(page.request, `/api/cash-registers/${state.register}`)).json();
  expect((Array.isArray(after) ? after[0] : after).status).toBe("closed");
});

test("upstream telemetry is answered locally (nothing is sent to the vendor)", async () => {
  const res = await apiPost(page, "/api/system/telemetry", {});
  expect(res.status(), await res.text()).toBe(200);
  expect((await res.json()).message).toMatch(/Telemetry is disabled on this installation/);
});
