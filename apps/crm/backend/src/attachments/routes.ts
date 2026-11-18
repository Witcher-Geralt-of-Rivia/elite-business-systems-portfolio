/**
 * Local attachment storage (replaces the Supabase Storage bucket).
 *
 * Upload:   POST /api/attachments   body = raw file bytes (application/octet-stream),
 *           headers X-File-Name (URI-encoded) and X-File-Type. Returns an RAFile-shaped object
 *           { src, path, title, type } that the UI stores inside notes, logos and avatars.
 * Download: GET /api/attachments/:id   (authenticated). Raster images are served inline;
 *           everything else as a download, always with nosniff and a sandboxing CSP, so an
 *           uploaded HTML/SVG file can never run script in the CRM's origin.
 *
 * Files are stored under a server-generated UUID name; the client-supplied name is metadata only.
 */
import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { FastifyInstance } from "fastify";
import { requireUser } from "../auth/routes.ts";
import type { Db } from "../db.ts";
import { audit } from "../resources/service.ts";
import { BadRequest, Forbidden, NotFound } from "../resources/schema.ts";

export const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;
const INLINE_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]);
const UUID = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$";

function cleanName(raw: unknown): string {
  let name = "file";
  try {
    name = decodeURIComponent(String(raw ?? "file"));
  } catch {
    /* keep default */
  }
  // Strip path components and control characters; keep it short.
  name = name.split(/[\\/]/).pop()!.replace(/[\u0000-\u001f\u007f"]/g, "").trim();
  return (name || "file").slice(0, 200);
}

function cleanType(raw: unknown): string {
  const t = String(raw ?? "").toLowerCase().trim();
  return /^[a-z0-9.+-]+\/[a-z0-9.+-]+$/.test(t) ? t.slice(0, 100) : "application/octet-stream";
}

export function registerAttachmentRoutes(app: FastifyInstance, db: Db, rootDir: string) {
  app.register(async (r) => {
    r.addContentTypeParser("application/octet-stream", { parseAs: "buffer", bodyLimit: MAX_ATTACHMENT_BYTES }, (_req, body, done) =>
      done(null, body),
    );
    r.addHook("preHandler", requireUser);

    r.post("/api/attachments", async (req, reply) => {
      if (req.user!.role === "showcase") throw new Forbidden("Your role cannot upload files.");
      const body = req.body;
      if (!Buffer.isBuffer(body) || body.length === 0) throw new BadRequest("Send the file bytes as application/octet-stream.");
      const id = randomUUID();
      const name = cleanName(req.headers["x-file-name"]);
      const type = cleanType(req.headers["x-file-type"]);
      const sha256 = createHash("sha256").update(body).digest("hex");
      await mkdir(rootDir, { recursive: true });
      await writeFile(join(rootDir, id), body, { flag: "wx" });
      try {
        await db.query(
          `insert into attachments (id, storage_path, original_name, mime_type, size_bytes, sha256, uploaded_by)
           values ($1, $2, $3, $4, $5, $6, $7)`,
          [id, id, name, type, body.length, sha256, req.user!.salesId],
        );
      } catch (error) {
        await rm(join(rootDir, id), { force: true });
        throw error;
      }
      await audit(db, req.user, "upload", "attachments", id, { name, type, size: body.length }, req.ip);
      return reply.code(201).send({ src: `/api/attachments/${id}`, path: id, title: name, type });
    });

    r.get("/api/attachments/:id", { schema: { params: { type: "object", properties: { id: { type: "string", pattern: UUID } } } } }, async (req, reply) => {
      const { id } = req.params as { id: string };
      const { rows } = await db.query(`select storage_path, original_name, mime_type, size_bytes from attachments where id = $1`, [id]);
      const meta = rows[0];
      if (!meta) throw new NotFound("Attachment not found");
      const file = join(rootDir, meta.storage_path);
      try {
        await stat(file);
      } catch {
        throw new NotFound("Attachment content missing");
      }
      const inline = INLINE_TYPES.has(meta.mime_type);
      const encoded = encodeURIComponent(meta.original_name);
      reply
        .header("Content-Type", inline ? meta.mime_type : "application/octet-stream")
        .header("Content-Length", String(meta.size_bytes))
        .header("Content-Disposition", `${inline ? "inline" : "attachment"}; filename*=UTF-8''${encoded}`)
        .header("Content-Security-Policy", "default-src 'none'; sandbox");
      return reply.send(createReadStream(file));
    });
  });
}

/**
 * Deletes attachments no longer referenced by any note, logo, avatar or configuration, after a
 * grace period (an upload is referenced only once the form that triggered it is saved).
 */
export async function purgeOrphanAttachments(db: Db, rootDir: string, graceHours = 24): Promise<number> {
  const { rows } = await db.query(
    `select a.id, a.storage_path from attachments a
      where a.created_at < now() - make_interval(hours => $1)
        and not exists (select 1 from contact_notes n where array_to_string(n.attachments, ' ') like '%' || a.id || '%')
        and not exists (select 1 from deal_notes n where array_to_string(n.attachments, ' ') like '%' || a.id || '%')
        and not exists (select 1 from companies x where x.logo::text like '%' || a.id || '%')
        and not exists (select 1 from contacts x where x.avatar::text like '%' || a.id || '%')
        and not exists (select 1 from sales x where x.avatar::text like '%' || a.id || '%')
        and not exists (select 1 from configuration x where x.config::text like '%' || a.id || '%')`,
    [graceHours],
  );
  for (const row of rows) {
    await db.query(`delete from attachments where id = $1`, [row.id]);
    await rm(join(rootDir, row.storage_path), { force: true });
  }
  return rows.length;
}
