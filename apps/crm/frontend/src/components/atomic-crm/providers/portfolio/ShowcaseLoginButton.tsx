/**
 * "Explore the live demo" on the login page: starts a read-only visitor session (no credentials
 * involved). Rendered only when the API reports showcase access as enabled.
 */
import { useQuery } from "@tanstack/react-query";
import { useNotify, useTranslate } from "ra-core";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { apiFetch } from "./http";
import { resetIdentityCache } from "./authProvider";

export const ShowcaseLoginButton = () => {
  const translate = useTranslate();
  const notify = useNotify();
  const [loading, setLoading] = useState(false);
  const { data } = useQuery({
    queryKey: ["portfolio", "init-state"],
    queryFn: () => apiFetch<{ initialized: boolean; showcase?: boolean }>("/auth/init-state"),
    staleTime: 60_000,
  });
  if (!data?.showcase) return null;

  const start = async () => {
    setLoading(true);
    try {
      await apiFetch("/auth/showcase", { method: "POST", body: {} });
      resetIdentityCache();
      window.location.assign(`${window.location.pathname}#/`);
    } catch (error) {
      notify((error as Error).message, { type: "error" });
      setLoading(false);
    }
  };

  return (
    <div className="flex flex-col gap-2 border-t pt-4">
      <Button type="button" variant="outline" className="cursor-pointer" disabled={loading} onClick={start}>
        {translate("crm.showcase.explore", { _: "Explore the live demo (read-only)" })}
      </Button>
      <p className="text-xs text-center text-muted-foreground">
        {translate("crm.showcase.explore_hint", {
          _: "Fictional company and simulated activity. No sign-up needed.",
        })}
      </p>
    </div>
  );
};
