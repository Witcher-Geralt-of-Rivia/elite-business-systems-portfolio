/**
 * Uploads files picked in the UI (notes attachments, company logos, avatars, theme logos) to the
 * portfolio API's private attachment store. Same contract as upstream's uploadToBucket(): the
 * RAFile is returned with `src`/`path`/`type` pointing at the stored copy.
 */
import type { RAFile } from "../../types";
import { API_BASE, CSRF_HEADER } from "./http";

const isLocal = (src: string | undefined) => !!src && (src.startsWith("blob:") || src.startsWith("data:"));

export async function uploadFile(fi: RAFile): Promise<RAFile> {
  // Already stored (or an external URL): nothing to do.
  if (!isLocal(fi?.src) && !(fi?.rawFile instanceof File)) return fi;
  const file = fi.rawFile instanceof File ? fi.rawFile : null;
  const blob = file ?? (await fetch(fi.src).then((r) => (r.ok ? r.blob() : null)).catch(() => null));
  if (!blob) return fi;

  const name = file?.name ?? fi.title ?? "file";
  const response = await fetch(`${API_BASE}/attachments`, {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/octet-stream",
      "X-File-Name": encodeURIComponent(name),
      "X-File-Type": blob.type || "application/octet-stream",
      [CSRF_HEADER]: "1",
    },
    body: blob,
  });
  if (!response.ok) {
    const detail = await response.json().catch(() => ({}));
    throw new Error(detail?.error ?? "Failed to upload attachment");
  }
  const stored = (await response.json()) as { src: string; path: string; title: string; type: string };
  return { ...fi, src: stored.src, path: stored.path, title: fi.title ?? stored.title, type: stored.type, rawFile: undefined as any };
}

export async function uploadFiles(files: RAFile[] | undefined | null): Promise<RAFile[] | undefined | null> {
  if (!files) return files;
  return Promise.all(files.map(uploadFile));
}

/** Theme logos are stored as plain URLs in the configuration. */
export async function uploadLogo(logo: unknown): Promise<string> {
  if (typeof logo === "string") return logo;
  const fi = logo as RAFile | undefined;
  if (!fi) return "";
  return (await uploadFile(fi)).src ?? "";
}
