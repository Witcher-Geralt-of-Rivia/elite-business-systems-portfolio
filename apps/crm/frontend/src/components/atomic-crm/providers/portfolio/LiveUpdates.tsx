/**
 * Subscribes to the API's Server-Sent Events stream (/api/events) and refreshes the affected
 * cached queries, so lists, kanban boards and dashboards update when a teammate — or the
 * server-side simulation — changes data. Event payloads are only used as invalidation hints.
 */
import { useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { API_BASE } from "./http";

/** Which cached resources depend on each table (views and the activity feed included). */
const AFFECTED: Record<string, string[]> = {
  companies: ["companies", "companies_summary", "activity_log"],
  contacts: ["contacts", "contacts_summary", "companies", "activity_log"],
  contact_notes: ["contact_notes", "contacts", "contacts_summary", "activity_log"],
  deals: ["deals", "companies", "activity_log"],
  deal_notes: ["deal_notes", "activity_log"],
  tasks: ["tasks", "contacts", "contacts_summary"],
  tags: ["tags"],
  sales: ["sales"],
};

const FLUSH_MS = 750;

export const LiveUpdates = () => {
  const queryClient = useQueryClient();

  useEffect(() => {
    if (typeof EventSource === "undefined") return;
    const pending = new Set<string>();
    let timer: ReturnType<typeof setTimeout> | null = null;

    // Bursts (e.g. a deal moved on the kanban re-indexes a column) are coalesced into one refresh.
    const flush = () => {
      timer = null;
      for (const resource of pending) queryClient.invalidateQueries({ queryKey: [resource] });
      pending.clear();
    };

    const source = new EventSource(`${API_BASE}/events`, { withCredentials: true });
    source.addEventListener("change", (event) => {
      try {
        const { table } = JSON.parse((event as MessageEvent).data) as { table: string };
        (AFFECTED[table] ?? [table]).forEach((r) => pending.add(r));
        if (!timer) timer = setTimeout(flush, FLUSH_MS);
      } catch {
        /* ignore malformed events */
      }
    });
    return () => {
      source.close();
      if (timer) clearTimeout(timer);
    };
  }, [queryClient]);

  return null;
};
