/**
 * AuthProvider for the portfolio CRM API: application-managed sessions in an httpOnly cookie.
 * The browser never sees the session token; identity comes from GET /api/auth/me.
 */
import type { AuthProvider } from "ra-core";
import { canAccess } from "../commons/canAccess";
import { apiFetch } from "./http";

interface Identity {
  id: number;
  fullName: string;
  avatar?: string;
  email: string;
  role: "admin" | "manager" | "sales_rep" | "showcase";
  administrator: boolean;
}

let cachedIdentity: Identity | null = null;

/** Forget the cached identity (e.g. after a visitor session was started outside login()). */
export const resetIdentityCache = () => {
  cachedIdentity = null;
};


async function fetchIdentity(): Promise<Identity> {
  if (cachedIdentity) return cachedIdentity;
  cachedIdentity = await apiFetch<Identity>("/auth/me");
  return cachedIdentity;
}

const PUBLIC_ROUTES = ["/set-password", "/forgot-password", "/sign-up"];

const onPublicRoute = () =>
  PUBLIC_ROUTES.some((r) => window.location.pathname === r || window.location.hash.includes(`#${r}`));

export const getAuthProvider = (): AuthProvider => ({
  async login({ email, password }: { email: string; password: string }) {
    cachedIdentity = await apiFetch<Identity>("/auth/login", { method: "POST", body: { email, password } });
  },

  async logout() {
    cachedIdentity = null;
    try {
      await apiFetch("/auth/logout", { method: "POST", body: {} });
    } catch {
      // Session already gone server-side: nothing else to clean up.
    }
  },

  async checkAuth() {
    if (onPublicRoute()) return;
    try {
      await fetchIdentity();
    } catch {
      throw { redirectTo: "/login", message: false };
    }
  },

  async checkError(error: { status?: number }) {
    if (error?.status === 401) {
      cachedIdentity = null;
      throw new Error("Session expired");
    }
  },

  async getIdentity() {
    const identity = await fetchIdentity();
    return { id: identity.id, fullName: identity.fullName, avatar: identity.avatar, role: identity.role };
  },

  async canAccess(params) {
    try {
      const identity = await fetchIdentity();
      // Visitors (role "showcase") are NOT denied create/edit here: ra-core's create/edit
      // controllers redirect to "Access denied" when refused, and Atomic CRM embeds such forms in
      // read pages (e.g. the note form on a contact). The API refuses every visitor write and the
      // UI shows its "read-only demo" message; the banner states it permanently.
      // Upstream UI distinguishes admin vs everyone else; finer rules are enforced by the API.
      return canAccess(identity.administrator ? "admin" : "user", params);
    } catch {
      return false;
    }
  },
});
