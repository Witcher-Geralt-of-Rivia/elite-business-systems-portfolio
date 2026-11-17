import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth/routes.ts";
import type { Db } from "../db.ts";
import { audit } from "../resources/service.ts";

/** Singleton UI configuration (deal stages, sectors, branding...). Readable by the team, writable by admins. */
export function registerConfigurationRoutes(app: FastifyInstance, db: Db) {
  app.get("/api/configuration", { preHandler: requireUser }, async () => {
    const { rows } = await db.query(`select config from configuration where id = 1`);
    return { data: rows[0]?.config ?? {} };
  });

  app.put(
    "/api/configuration",
    { preHandler: requireUser, schema: { body: { type: "object" } }, bodyLimit: 2_097_152 },
    async (req, reply) => {
      if (req.user!.role !== "admin") return reply.code(403).send({ error: "Only administrators can change settings." });
      const { rows } = await db.query(`update configuration set config = $1 where id = 1 returning config`, [
        JSON.stringify(req.body),
      ]);
      await audit(db, { salesId: req.user!.salesId, kind: "user" }, "update", "configuration", 1, null, req.ip);
      return { data: rows[0].config };
    },
  );
}
