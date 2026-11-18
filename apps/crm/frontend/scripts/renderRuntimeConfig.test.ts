import { describe, expect, it } from "vitest";
import { renderRuntimeConfig } from "./renderRuntimeConfig.ts";

// Runs the rendered config.js the way the browser does, against a fake window.
const loadConfig = (env: Record<string, string | undefined>) => {
  const fakeWindow: { _atomicCrmConfig?: unknown } = {};
  new Function("window", renderRuntimeConfig(env))(fakeWindow);
  return fakeWindow._atomicCrmConfig;
};

describe("renderRuntimeConfig", () => {
  it("exposes the deployment settings to the app", () => {
    expect(
      loadConfig({
        VITE_MCP_URL: "https://crm.example.com/mcp",
        VITE_INBOUND_EMAIL: "crm@inbound.acme.com",
        VITE_ATTACHMENTS_BUCKET: "files",
        VITE_GOOGLE_WORKPLACE_DOMAIN: "acme.com",
      }),
    ).toEqual({
      mcpUrl: "https://crm.example.com/mcp",
      inboundEmail: "crm@inbound.acme.com",
      attachmentsBucket: "files",
      googleWorkplaceDomain: "acme.com",
    });
  });

  it("never writes other environment variables, which may be secrets", () => {
    const script = renderRuntimeConfig({
      VITE_MCP_URL: "https://crm.example.com/mcp",
      SERVICE_ROLE_KEY: "secret-service-role-key",
      SUPABASE_DB_PASSWORD: "secret-db-password",
    });

    expect(script).not.toContain("secret");
  });

  it("leaves out unset and empty settings", () => {
    expect(
      loadConfig({
        VITE_MCP_URL: "https://crm.example.com/mcp",
        VITE_INBOUND_EMAIL: "",
      }),
    ).toEqual({ mcpUrl: "https://crm.example.com/mcp" });
  });

  it("turns the flags into booleans", () => {
    expect(
      loadConfig({
        VITE_IS_DEMO: "true",
        VITE_DISABLE_EMAIL_PASSWORD_AUTHENTICATION: "false",
      }),
    ).toEqual({ isDemo: true, disableEmailPasswordAuthentication: false });
  });
});
