import { defineConfig, devices } from "@playwright/test";

/**
 * Browser tests for the POS (NexoPOS + HarborPine module).
 *   POS_E2E_BASE_URL       site under test (local loopback site, isolated e2e instance, or public URL once authorized)
 *   POS_E2E_ADMIN_USER / POS_E2E_ADMIN_PASSWORD   store administrator (read from the restricted secrets folder by the runner)
 */
export default defineConfig({
  testDir: ".",
  testMatch: /.*\.spec\.ts$/,
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [["list"], ["json", { outputFile: "test-results/pos-e2e.json" }]],
  timeout: 90_000,
  use: {
    baseURL: process.env.POS_E2E_BASE_URL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    actionTimeout: 20_000,
    navigationTimeout: 45_000,
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
});
