import { defineConfig, devices } from "@playwright/test";

/**
 * Browser tests for the portfolio deployment (Atomic CRM UI on the portfolio API).
 * The app uses hash routing (react-admin default) with relative assets: navigate to "/#/..." URLs.
 * Runs against a live base URL, e.g.:
 *   CRM_E2E_BASE_URL=https://crm.<VPS_IP>.sslip.io CRM_E2E_EMAIL=... CRM_E2E_PASSWORD=... \
 *   npx playwright test -c playwright.portfolio.config.ts
 */
export default defineConfig({
  testDir: "./e2e-portfolio",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [["list"], ["json", { outputFile: "test-results/portfolio-e2e.json" }]],
  timeout: 60_000,
  use: {
    baseURL: process.env.CRM_E2E_BASE_URL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
});
