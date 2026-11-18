import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth/routes.ts";
import type { Db } from "../db.ts";

export const SEARCH_RESOURCES = ["companies", "contacts", "deals", "tasks", "contact_notes", "deal_notes"] as const;

/**
 * GET /api/search?q=&resources=a,b&max=  -> SearchResult[] (same shape as upstream's global_search RPC).
 * Ranking, normalization and per-resource caps live in crm.global_search() (migration 0002).
 */
export function registerSearchRoutes(app: FastifyInstance, db: Db) {
  app.get(
    "/api/search",
    {
      preHandler: requireUser,
      schema: {
        querystring: {
          type: "object",
          required: ["q"],
          properties: {
            q: { type: "string", maxLength: 200 },
            resources: { type: "string", maxLength: 200 },
            max: { type: "integer", minimum: 1, maximum: 200, default: 50 },
          },
        },
      },
    },
    async (req) => {
      const { q, resources, max } = req.query as { q: string; resources?: string; max: number };
      const requested = resources
        ? resources.split(",").filter((r): r is (typeof SEARCH_RESOURCES)[number] =>
            (SEARCH_RESOURCES as readonly string[]).includes(r),
          )
        : null;
      if (requested && requested.length === 0) return [];
      const { rows } = await db.query(
        `select resource, record_id, title, subtitle, contact_id, deal_id, date, content
           from global_search($1, $2::text[], $3)`,
        [q, requested, max],
      );
      return rows;
    },
  );
}
