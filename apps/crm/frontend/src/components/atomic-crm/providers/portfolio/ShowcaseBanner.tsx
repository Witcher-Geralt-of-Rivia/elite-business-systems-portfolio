/** Persistent notice for read-only visitor sessions. */
import { useGetIdentity, useTranslate } from "ra-core";

export const ShowcaseBanner = () => {
  const { identity } = useGetIdentity();
  const translate = useTranslate();
  if ((identity as { role?: string } | undefined)?.role !== "showcase") return null;
  return (
    <div
      role="status"
      className="fixed bottom-3 left-1/2 -translate-x-1/2 z-50 max-w-[calc(100vw-2rem)] rounded-full border bg-background/95 px-4 py-1.5 text-xs shadow-md backdrop-blur"
    >
      {translate("crm.showcase.banner", {
        _: "Read-only demo · fictional data, live simulated activity · changes are disabled",
      })}
    </div>
  );
};
