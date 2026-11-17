import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth/routes.ts";
import { BadRequest } from "./schema.ts";
import type { ResourceService } from "./service.ts";

function parseFilter(raw: unknown): Record<string, unknown> {
  if (raw == null || raw === "") return {};
  try {
    const parsed = JSON.parse(String(raw));
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error();
    return parsed;
  } catch {
    throw new BadRequest("filter must be a JSON object");
  }
}

const idParam = {
  type: "object",
  required: ["resource", "id"],
  properties: { resource: { type: "string", pattern: "^[a-z_]+$" }, id: { type: "string", pattern: "^[0-9]{1,18}$" } },
} as const;
const resourceParam = {
  type: "object",
  required: ["resource"],
  properties: { resource: { type: "string", pattern: "^[a-z_]+$" } },
} as const;

export function registerResourceRoutes(app: FastifyInstance, service: ResourceService) {
  app.register(async (r) => {
    r.addHook("preHandler", requireUser);

    r.get("/api/r/:resource", { schema: { params: resourceParam } }, async (req) => {
      const { resource } = req.params as { resource: string };
      const q = req.query as Record<string, string | undefined>;
      return service.list(resource, {
        filter: parseFilter(q.filter),
        sort: q.sort,
        order: q.order,
        start: Number(q.start ?? 0),
        end: Number(q.end ?? 25),
      });
    });

    r.get("/api/r/:resource/:id", { schema: { params: idParam } }, async (req) => {
      const { resource, id } = req.params as { resource: string; id: string };
      return { data: await service.getOne(resource, id) };
    });

    r.post("/api/r/:resource", { schema: { params: resourceParam, body: { type: "object" } } }, async (req, reply) => {
      const { resource } = req.params as { resource: string };
      const data = await service.create(resource, req.user!, req.body as Record<string, unknown>, req.ip);
      return reply.code(201).send({ data });
    });

    r.patch("/api/r/:resource/:id", { schema: { params: idParam, body: { type: "object" } } }, async (req) => {
      const { resource, id } = req.params as { resource: string; id: string };
      return { data: await service.update(resource, req.user!, id, req.body as Record<string, unknown>, req.ip) };
    });

    r.delete("/api/r/:resource/:id", { schema: { params: idParam } }, async (req) => {
      const { resource, id } = req.params as { resource: string; id: string };
      return { data: await service.delete(resource, req.user!, id, req.ip) };
    });
  });
}
