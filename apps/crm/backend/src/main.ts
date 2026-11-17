import { buildApp } from "./app.ts";
import { purgeExpiredSessions } from "./auth/sessions.ts";
import { loadConfig } from "./config.ts";
import { createPool } from "./db.ts";

const config = loadConfig();
const db = createPool(config.databaseUrl);
const app = await buildApp(config, db);

const purge = setInterval(() => {
  purgeExpiredSessions(db).catch((err) => app.log.warn({ err }, "session purge failed"));
}, 3600_000);

async function shutdown(signal: string) {
  app.log.info({ signal }, "shutting down");
  clearInterval(purge);
  await app.close();
  await db.end();
  process.exit(0);
}
process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("SIGTERM", () => void shutdown("SIGTERM"));

await app.listen({ host: config.host, port: config.port });
