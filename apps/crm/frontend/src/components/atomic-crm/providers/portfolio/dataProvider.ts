/**
 * DataProvider for the portfolio CRM API (apps/crm/backend), replacing the Supabase provider.
 *
 * Filters are forwarded unchanged in the PostgREST-style grammar the UI already uses
 * ("field@op", "@or", "q"); the server validates and translates them to SQL. Search
 * columns, resource->view mapping and ownership rules all live server-side.
 */
import type { DataProvider, GetListParams, GetListResult, Identifier, RaRecord } from "ra-core";
import type { ConfigurationContextValue } from "../../root/ConfigurationContext";
import type { Deal, Sale, SalesFormData, SearchResourceName, SearchResult, SignUpData } from "../../types";
import { apiFetch } from "./http";

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

class NotAvailableYet extends Error {
  constructor(feature: string) {
    super(`${feature} is not available in this build yet.`);
    this.name = "NotAvailableYet";
  }
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
      return apiFetch<{ data: any }>(resourcePath(resource), { method: "POST", body: params.data });
    },
    async update(resource, params) {
      return apiFetch<{ data: any }>(resourcePath(resource, params.id), { method: "PATCH", body: params.data });
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
      const { data } = await apiFetch<{ data: ConfigurationContextValue }>("/configuration", {
        method: "PUT",
        body: config,
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

    // ---- Implemented server-side in milestone M4 (see docs/CRM_SUPABASE_MIGRATION.md) ----
    async signUp(_data: SignUpData): Promise<{ id: string; email: string; password: string }> {
      throw new NotAvailableYet("First-run sign-up");
    },
    async salesCreate(_body: SalesFormData): Promise<Sale> {
      throw new NotAvailableYet("Team member creation");
    },
    async salesUpdate(_id: Identifier, _data: Partial<Omit<SalesFormData, "password">>): Promise<Sale> {
      throw new NotAvailableYet("Team member editing");
    },
    async updatePassword(_id: Identifier): Promise<boolean> {
      throw new NotAvailableYet("Password change");
    },
    async globalSearch(
      _query: string,
      _resources: readonly SearchResourceName[],
      _maxResults: number,
    ): Promise<SearchResult[]> {
      throw new NotAvailableYet("Global search");
    },
    async mergeContacts(_sourceId: Identifier, _targetId: Identifier): Promise<unknown> {
      throw new NotAvailableYet("Contact merge");
    },
  };
};

export type CrmDataProvider = ReturnType<typeof getDataProvider>;
