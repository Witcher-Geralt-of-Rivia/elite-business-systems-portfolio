export interface AppConfig {
  databaseUrl: string;
  host: string;
  port: number;
  publicOrigin: string;
  cookieSecure: boolean;
  sessionTtlHours: number;
  attachmentsDir: string;
  logLevel: string;
  loginRateLimitPerMinute: number;
  /** Live server-side simulation (off unless CRM_SIMULATION=live). */
  simulation: { live: boolean; tickSeconds: number; intensity: number };
}

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable ${name}`);
  return value;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const publicOrigin = required("CRM_PUBLIC_ORIGIN");
  return {
    databaseUrl: required("CRM_DATABASE_URL"),
    host: env.CRM_HOST ?? "127.0.0.1",
    port: Number(env.CRM_PORT ?? 8810),
    publicOrigin,
    cookieSecure: (env.CRM_COOKIE_SECURE ?? "true") !== "false",
    sessionTtlHours: Number(env.CRM_SESSION_TTL_HOURS ?? 12),
    attachmentsDir: env.CRM_ATTACHMENTS_DIR ?? "C:/srv/portfolio/crm/files",
    logLevel: env.CRM_LOG_LEVEL ?? "info",
    loginRateLimitPerMinute: Number(env.CRM_LOGIN_RATE_LIMIT_PER_MINUTE ?? 10),
    simulation: {
      live: env.CRM_SIMULATION === "live",
      tickSeconds: Math.max(10, Number(env.CRM_SIM_TICK_SECONDS ?? 60)),
      intensity: Math.min(20, Math.max(0.1, Number(env.CRM_SIM_INTENSITY ?? 1))),
    },
  };
}
