/**
 * DataProvider for the portfolio CRM API (apps/crm/backend), replacing the Supabase provider.
 *
 * Filters are forwarded unchanged in the PostgREST-style grammar the UI already uses
 * ("field@op", "@or", "q"); the server validates and translates them to SQL. Search
 * columns, resource->view mapping and ownership rules all live server-side.
 */
import type { DataProvider, GetListParams, GetListResult, Identifier, RaRecord } from "ra-core";
import type { ConfigurationContextValue } from "../../root/ConfigurationContext";
import type { Deal, RAFile, Sale, SalesFormData, SearchResourceName, SearchResult, SignUpData } from "../../types";
import { uploadFile, uploadFiles, uploadLogo } from "./files";
import { apiFetch } from "./http";
import { showOneTimeLink } from "./OneTimeLinkDialog";

interface ListResponse {
  data: RaRecord[];
  total: number;
}

const listQuery = (params: Pick<GetListParams, "pagination" | "sort" | "filter">) => {
  const page = params.pagination?.page ?? 1;
  const perPage = params.pagination?.perPage ?? 25;
  return {
    filter: params.filter ?? {},
    sort: params.sort?.field,
    order: params.sort?.order,
    start: String((page - 1) * perPage),
    end: String(page * perPage),
  };
};

const resourcePath = (resource: string, id?: Identifier) =>
  `/r/${encodeURIComponent(resource)}${id === undefined ? "" : `/${encodeURIComponent(String(id))}`}`;

/** Upstream's activity_log view exposes snake_case columns; the Activity type is camelCase. */
const mapActivity = (row: RaRecord) => ({
  ...row,
  contactNote: row.contact_note ?? undefined,
  dealNote: row.deal_note ?? undefined,
  contact_note: undefined,
  deal_note: undefined,
});

/** Uploads files picked in forms before the record is saved (upstream lifecycle callbacks). */
async function withStoredFiles(resource: string, data: any) {
  if (!data) return data;
  if ((resource === "contact_notes" || resource === "deal_notes") && data.attachments) {
    return { ...data, attachments: await uploadFiles(data.attachments) };
  }
  if (resource === "companies" && data.logo?.rawFile instanceof File) {
    return { ...data, logo: await uploadFile(data.logo) };
  }
  if ((resource === "contacts" || resource === "sales") && data.avatar?.rawFile instanceof File) {
    return { ...data, avatar: await uploadFile(data.avatar) };
  }
  return data;
}

/** Re-throws API errors with the `code`/`email` fields the team UI maps to messages. */
function withErrorCode(error: any): never {
  const body = error?.body ?? {};
  throw Object.assign(new Error(body.error ?? error?.message ?? "Request failed"), {
    status: error?.status,
    code: body.code,
    email: body.email,
  });
}

export const getDataProvider = () => {
  const baseDataProvider: DataProvider = {
    async getList(resource, params) {
      const result = await apiFetch<ListResponse>(resourcePath(resource), { query: listQuery(params) });
      const data = resource === "activity_log" ? result.data.map(mapActivity) : result.data;
      return { data, total: result.total } as any;
    },
    async getOne(resource, params) {
      return apiFetch<{ data: any }>(resourcePath(resource, params.id));
    },
    async getMany(resource, params) {
      const { data } = await apiFetch<ListResponse>(resourcePath(resource), {
        query: { filter: { "id@in": params.ids }, start: "0", end: String(Math.max(params.ids.length, 1)) },
      });
      return { data } as any;
    },
    async getManyReference(resource, params) {
      const result = await apiFetch<ListResponse>(resourcePath(resource), {
        query: listQuery({ ...params, filter: { ...params.filter, [params.target]: params.id } }),
      });
      return result as any;
    },
    async create(resource, params) {
      const body = await withStoredFiles(resource, params.data);
      return apiFetch<{ data: any }>(resourcePath(resource), { method: "POST", body });
    },
    async update(resource, params) {
      const body = await withStoredFiles(resource, params.data);
      return apiFetch<{ data: any }>(resourcePath(resource, params.id), { method: "PATCH", body });
    },
    async updateMany(resource, params) {
      await Promise.all(
        params.ids.map((id) => apiFetch(resourcePath(resource, id), { method: "PATCH", body: params.data })),
      );
      return { data: params.ids };
    },
    async delete(resource, params) {
      return apiFetch<{ data: any }>(resourcePath(resource, params.id), { method: "DELETE" });
    },
    async deleteMany(resource, params) {
      await Promise.all(params.ids.map((id) => apiFetch(resourcePath(resource, id), { method: "DELETE" })));
      return { data: params.ids };
    },
  };

  return {
    ...baseDataProvider,

    // Same shape as upstream's CrmDataProvider.getList: accepts a type argument (the FakeRest demo
    // provider calls getList<Sale>()) but returns loosely typed rows (it also returns Activity rows).
    async getList<RecordType extends RaRecord = any>(
      resource: string,
      params: GetListParams,
    ): Promise<GetListResult<RecordType | any>> {
      return baseDataProvider.getList(resource, params);
    },

    async isInitialized(): Promise<boolean> {
      const { initialized } = await apiFetch<{ initialized: boolean }>("/auth/init-state");
      return initialized;
    },

    async getConfiguration(): Promise<ConfigurationContextValue> {
      const { data } = await apiFetch<{ data: ConfigurationContextValue }>("/configuration");
      return data ?? {};
    },

    async updateConfiguration(config: ConfigurationContextValue): Promise<ConfigurationContextValue> {
      const body = {
        ...config,
        lightModeLogo: config.lightModeLogo ? await uploadLogo(config.lightModeLogo) : config.lightModeLogo,
        darkModeLogo: config.darkModeLogo ? await uploadLogo(config.darkModeLogo) : config.darkModeLogo,
      };
      const { data } = await apiFetch<{ data: ConfigurationContextValue }>("/configuration", {
        method: "PUT",
        body,
      });
      return data;
    },

    /** Same algorithm as upstream: re-index the stage column with the unarchived deal first. */
    async unarchiveDeal(deal: Deal) {
      const { data: deals } = await baseDataProvider.getList("deals", {
        filter: { stage: deal.stage },
        pagination: { page: 1, perPage: 1000 },
        sort: { field: "index", order: "ASC" },
      });
      return Promise.all(
        (deals as Deal[]).map((d, index) =>
          baseDataProvider.update("deals", {
            id: d.id,
            data: { index: d.id === deal.id ? 0 : index + 1, archived_at: d.id === deal.id ? null : d.archived_at },
            previousData: d,
          }),
        ),
      );
    },

    /** First-run sign-up: accepted by the API only while the instance has no users. */
    async signUp(data: SignUpData): Promise<{ id: string; email: string; password: string }> {
      const created = await apiFetch<{ id: string; email: string }>("/auth/signup", { method: "POST", body: data });
      return { ...created, password: data.password };
    },

    /** Invites a team member; the one-time link is shown to the administrator (no email service). */
    async salesCreate(body: SalesFormData): Promise<Sale> {
      const payload = { ...body, avatar: body.avatar ? await uploadFile(body.avatar as unknown as RAFile) : undefined };
      const res = await apiFetch<{ data: Sale; invitation: { url: string; expiresAt: string } }>("/users", {
        method: "POST",
        body: payload,
      }).catch(withErrorCode);
      showOneTimeLink({ kind: "invite", name: `${res.data.first_name} ${res.data.last_name}`, ...res.invitation });
      return res.data;
    },

    async salesUpdate(id: Identifier, data: Partial<Omit<SalesFormData, "password">>): Promise<Sale> {
      const { email, secondary_emails, first_name, last_name, administrator, disabled } = data;
      const avatar = (data.avatar as any)?.rawFile instanceof File ? await uploadFile(data.avatar as any) : data.avatar;
      const res = await apiFetch<{ data: Sale }>(`/users/${encodeURIComponent(String(id))}`, {
        method: "PATCH",
        body: { email, secondary_emails, first_name, last_name, administrator, disabled, avatar },
      }).catch(withErrorCode);
      return res.data;
    },

    /**
     * "Change password" on the profile page: issues a one-time link for the signed-in user and
     * opens it (upstream emailed a reset link instead).
     */
    async updatePassword(id: Identifier): Promise<boolean> {
      const link = await apiFetch<{ url: string }>(`/users/${encodeURIComponent(String(id))}/password-link`, { method: "POST" });
      window.location.assign(link.url);
      return true;
    },

    /** Administrators: one-time invitation / reset link for a team member, shown in a dialog. */
    async salesPasswordLink(id: Identifier, name?: string): Promise<void> {
      const link = await apiFetch<{ url: string; expiresAt: string; purpose: "invite" | "reset" }>(
        `/users/${encodeURIComponent(String(id))}/password-link`,
        { method: "POST" },
      );
      showOneTimeLink({ kind: link.purpose, name, url: link.url, expiresAt: link.expiresAt });
    },

    async globalSearch(
      query: string,
      resources: readonly SearchResourceName[],
      maxResults: number,
    ): Promise<SearchResult[]> {
      // apiFetch throws HttpError(status) so authProvider.checkError can log out an expired session.
      return apiFetch<SearchResult[]>("/search", {
        query: { q: query, resources: resources.join(","), max: String(maxResults) },
      });
    },

    /** Merges `sourceId` (deleted) into `targetId` in one server-side transaction. */
    async mergeContacts(sourceId: Identifier, targetId: Identifier): Promise<unknown> {
      const { data } = await apiFetch<{ data: unknown }>(`/contacts/${encodeURIComponent(String(sourceId))}/merge`, {
        method: "POST",
        body: { winnerId: Number(targetId) },
      });
      return data;
    },
  };
};

type PortfolioDataProvider = ReturnType<typeof getDataProvider>;
/** Portfolio-only extras are optional so upstream's FakeRest demo provider still satisfies the type. */
export type CrmDataProvider = Omit<PortfolioDataProvider, "salesPasswordLink"> &
  Partial<Pick<PortfolioDataProvider, "salesPasswordLink">>;
