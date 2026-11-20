import { defineConfig, devices } from "@playwright/test";

/**
 * Browser tests for ERPNext (Frappe Desk) on the native-Windows installation.
 *   ERP_E2E_BASE_URL         the private entry point (default http://127.0.0.1:8850)
 *   ERP_E2E_ADMIN_PASSWORD   Administrator password (read from the restricted secrets file by the runner)
 *   ERP_E2E_VIEWER_PASSWORD  password of the restricted test user the runner creates (permission checks)
 * The specs only READ business data, except one draft document in erp-desk.spec.ts which is deleted again.
 */
export default defineConfig({
  testDir: ".",
  testMatch: /.*\.spec\.ts$/,
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [["list"], ["json", { outputFile: "test-results/erp-e2e.json" }]],
  timeout: 120_000,
  use: {
    baseURL: process.env.ERP_E2E_BASE_URL ?? "http://127.0.0.1:8850",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    actionTimeout: 30_000,
    navigationTimeout: 60_000,
  },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } } },
    // Phone layout (Chromium with a Pixel 7 viewport, touch and user agent).
    { name: "mobile", use: { ...devices["Pixel 7"] } },
  ],
});
