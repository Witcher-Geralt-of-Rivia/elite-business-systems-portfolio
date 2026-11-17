import type { Role } from "../auth/sessions.ts";

export type Access = "none" | "read" | "own" | "all";

export interface ResourceDef {
  /** Base table that receives writes. */
  table: string;
  /** Relation used for list/getOne (a view may add computed columns). */
  readRelation: string;
  /** Columns searched by the `q` filter (on readRelation). */
  searchColumns?: readonly string[];
  /** Column holding the owning sales id, for record-level rules. */
  ownerColumn?: string;
  /** Write access per role: none | own (rows they own) | all. */
  write: Record<Role, Exclude<Access, "read">>;
  /** Columns API clients may never set. */
  protectedColumns?: readonly string[];
}

const TEAM_RECORD: ResourceDef["write"] = { admin: "all", manager: "all", sales_rep: "own", showcase: "none" };

// Search columns mirror upstream applyFullTextSearch() in providers/supabase/dataProvider.ts.
export const RESOURCES: Record<string, ResourceDef> = {
  companies: {
    table: "companies",
    readRelation: "companies_summary",
    searchColumns: ["name", "phone_number", "website", "zipcode", "city", "state_abbr"],
    ownerColumn: "sales_id",
    write: TEAM_RECORD,
  },
  contacts: {
    table: "contacts",
    readRelation: "contacts_summary",
    searchColumns: ["first_name", "last_name", "company_name", "title", "email_fts", "phone_fts", "background"],
    ownerColumn: "sales_id",
    write: TEAM_RECORD,
  },
  contacts_summary: {
    table: "contacts",
    readRelation: "contacts_summary",
    searchColumns: ["first_name", "last_name"],
    ownerColumn: "sales_id",
    write: { admin: "none", manager: "none", sales_rep: "none", showcase: "none" },
  },
  deals: {
    table: "deals",
    readRelation: "deals",
    searchColumns: ["name", "description"],
    ownerColumn: "sales_id",
    write: TEAM_RECORD,
  },
  contact_notes: { table: "contact_notes", readRelation: "contact_notes", ownerColumn: "sales_id", write: TEAM_RECORD },
  deal_notes: { table: "deal_notes", readRelation: "deal_notes", ownerColumn: "sales_id", write: TEAM_RECORD },
  tasks: { table: "tasks", readRelation: "tasks", ownerColumn: "sales_id", write: TEAM_RECORD },
  tags: {
    table: "tags",
    readRelation: "tags",
    write: { admin: "all", manager: "all", sales_rep: "all", showcase: "none" },
  },
  sales: {
    table: "sales",
    readRelation: "sales",
    searchColumns: ["first_name", "last_name"],
    // Team members are managed through /api/users (admin only), never via generic writes.
    write: { admin: "none", manager: "none", sales_rep: "none", showcase: "none" },
  },
  activity_log: {
    table: "activity_log",
    readRelation: "activity_log",
    write: { admin: "none", manager: "none", sales_rep: "none", showcase: "none" },
  },
};

export const ALWAYS_PROTECTED = ["id", "created_at", "updated_at"] as const;
