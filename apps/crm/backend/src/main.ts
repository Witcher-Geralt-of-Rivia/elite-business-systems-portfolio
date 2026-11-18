import { buildApp } from "./app.ts";
import { purgeOrphanAttachments } from "./attachments/routes.ts";
import { purgeExpiredSessions } from "./auth/sessions.ts";
import { loadConfig } from "./config.ts";
import { createPool } from "./db.ts";
import { SimulationWorker } from "./simulation/worker.ts";

const config = loadConfig();
const db = createPool(config.databaseUrl);
const app = await buildApp(config, db);

const purge = setInterval(() => {
  purgeExpiredSessions(db).catch((err) => app.log.warn({ err }, "session purge failed"));
  purgeOrphanAttachments(db, config.attachmentsDir).catch((err) => app.log.warn({ err }, "attachment purge failed"));
}, 3600_000);

const simulation = config.simulation.live
  ? new SimulationWorker(db, app.log, { tickSeconds: config.simulation.tickSeconds, intensity: config.simulation.intensity })
  : null;

async function shutdown(signal: string) {
  app.log.info({ signal }, "shutting down");
  clearInterval(purge);
  simulation?.stop();
  await app.close();
  await db.end();
  process.exit(0);
}
process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("SIGTERM", () => void shutdown("SIGTERM"));

await app.listen({ host: config.host, port: config.port });
if (simulation) {
  await simulation.start();
  app.log.info({ tickSeconds: config.simulation.tickSeconds, intensity: config.simulation.intensity }, "live simulation enabled");
}
