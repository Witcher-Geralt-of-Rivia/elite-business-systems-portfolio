/**
 * Local end-to-end stack for the portfolio M4 browser tests: `vite preview` serves the production
 * build and proxies /api to a portfolio API started on loopback against the crm_test database.
 */
import { defineConfig, mergeConfig } from "vite";
import base from "./vite.config";

export default mergeConfig(
  base,
  defineConfig({
    preview: {
      host: "127.0.0.1",
      port: 4173,
      strictPort: true,
      proxy: { "/api": { target: "http://127.0.0.1:8811", changeOrigin: false } },
    },
  }),
);
