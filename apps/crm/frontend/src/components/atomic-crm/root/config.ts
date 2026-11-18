/**
 * Deployment settings (inbound email, optional MCP endpoint...), read at runtime
 * so that one build can be deployed to any environment.
 *
 * They come from window._atomicCrmConfig, set by the config.js file that
 * index.html loads before the app, rendered by scripts/renderRuntimeConfig.ts.
 */
export interface RuntimeConfig {
  /** URL of an MCP endpoint for AI assistants; the Profile page section is hidden when unset. */
  mcpUrl?: string;
  isDemo?: boolean;
  inboundEmail?: string;
  attachmentsBucket?: string;
  googleWorkplaceDomain?: string;
  disableEmailPasswordAuthentication?: boolean;
}

declare global {
  interface Window {
    _atomicCrmConfig?: RuntimeConfig;
  }
}

export const config: RuntimeConfig = window._atomicCrmConfig ?? {};
