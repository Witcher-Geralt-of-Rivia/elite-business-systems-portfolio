export interface AppConfig {
  databaseUrl: string;
  host: string;
  port: number;
  publicOrigin: string;
  cookieSecure: boolean;
  sessionTtlHours: number;
  attachmentsDir: string;
  logLevel: string;
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
  };
}
