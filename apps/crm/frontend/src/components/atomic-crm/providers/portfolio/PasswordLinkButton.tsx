/**
 * Admin action on a team member: issue a one-time invitation (no password yet) or reset link.
 * The link is displayed by OneTimeLinkDialog; this deployment sends no email.
 */
import { useMutation } from "@tanstack/react-query";
import { useDataProvider, useNotify, useRecordContext, useTranslate } from "ra-core";
import { Button } from "@/components/ui/button";
import type { Sale } from "../../types";
import type { CrmDataProvider } from "../types";

export const PasswordLinkButton = () => {
  const record = useRecordContext<Sale>();
  const dataProvider = useDataProvider<CrmDataProvider>();
  const notify = useNotify();
  const translate = useTranslate();
  const { mutate, isPending } = useMutation({
    mutationFn: async () => dataProvider.salesPasswordLink?.(record!.id, `${record!.first_name} ${record!.last_name}`),
    onError: (e: Error) => notify(e.message, { type: "error" }),
  });
  if (!record || !dataProvider.salesPasswordLink) return null;
  return (
    <Button type="button" variant="outline" disabled={isPending} onClick={() => mutate()}>
      {translate("crm.auth.password_link", { _: "Password link" })}
    </Button>
  );
};
