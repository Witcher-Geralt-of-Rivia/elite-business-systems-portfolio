import { HttpError } from "ra-core";

/** Base path of the portfolio CRM API (served same-origin behind Caddy). */
export const API_BASE = "/api";

/** Must match CSRF_HEADER in apps/crm/backend/src/app.ts. */
const CSRF_HEADER = "X-CRM-CSRF";

const STATE_CHANGING = new Set(["POST", "PUT", "PATCH", "DELETE"]);

export async function apiFetch<T = unknown>(
  path: string,
  init: { method?: string; body?: unknown; query?: Record<string, unknown> } = {},
): Promise<T> {
  const method = init.method ?? "GET";
  const url = new URL(`${API_BASE}${path}`, window.location.origin);
  for (const [key, value] of Object.entries(init.query ?? {})) {
    if (value === undefined) continue;
    url.searchParams.set(key, typeof value === "string" ? value : JSON.stringify(value));
  }
  const headers: Record<string, string> = { Accept: "application/json" };
  if (init.body !== undefined) headers["Content-Type"] = "application/json";
  if (STATE_CHANGING.has(method)) headers[CSRF_HEADER] = "1";

  const response = await fetch(url, {
    method,
    headers,
    credentials: "same-origin",
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  const text = await response.text();
  const json = text ? safeJson(text) : null;
  if (!response.ok) {
    const message =
      (json && typeof json === "object" && "error" in json && String((json as { error: unknown }).error)) ||
      response.statusText;
    throw new HttpError(message, response.status, json);
  }
  return json as T;
}

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return { error: text.slice(0, 200) };
  }
}
