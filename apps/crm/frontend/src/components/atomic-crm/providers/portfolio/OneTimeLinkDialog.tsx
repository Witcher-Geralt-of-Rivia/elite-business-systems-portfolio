/**
 * Shows invitation / password-reset links to the person who requested them.
 *
 * This deployment has no email service, so instead of "an email has been sent" the API returns
 * the one-time link and the administrator hands it over through their own channel.
 */
import { useEffect, useState } from "react";
import { useTranslate } from "ra-core";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";

export interface OneTimeLink {
  kind: "invite" | "reset";
  name?: string;
  url: string;
  expiresAt: string;
}

type Listener = (link: OneTimeLink) => void;
const listeners = new Set<Listener>();

export function showOneTimeLink(link: OneTimeLink) {
  listeners.forEach((fn) => fn(link));
}

export const OneTimeLinkDialog = () => {
  const translate = useTranslate();
  const [link, setLink] = useState<OneTimeLink | null>(null);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    const fn: Listener = (l) => {
      setCopied(false);
      setLink(l);
    };
    listeners.add(fn);
    return () => {
      listeners.delete(fn);
    };
  }, []);

  if (!link) return null;
  const expires = new Date(link.expiresAt).toLocaleString();

  return (
    <Dialog open onOpenChange={(open) => !open && setLink(null)}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {link.kind === "invite"
              ? translate("crm.auth.invitation_link_title", { _: "Invitation link" })
              : translate("crm.auth.reset_link_title", { _: "Password reset link" })}
          </DialogTitle>
          <DialogDescription>
            {translate("crm.auth.one_time_link_details", {
              _: "Send this one-time link to %{name} through a channel you trust. It lets them choose a password and expires on %{expires}. It is shown only once.",
              name: link.name ?? translate("crm.auth.the_user", { _: "the user" }),
              expires,
            })}
          </DialogDescription>
        </DialogHeader>
        <Input readOnly value={link.url} onFocus={(e) => e.currentTarget.select()} aria-label="one-time link" />
        <DialogFooter>
          <Button
            variant="outline"
            onClick={async () => {
              await navigator.clipboard?.writeText(link.url);
              setCopied(true);
            }}
          >
            {copied ? translate("crm.auth.copied", { _: "Copied" }) : translate("crm.auth.copy_link", { _: "Copy link" })}
          </Button>
          <Button onClick={() => setLink(null)}>{translate("ra.action.close", { _: "Close" })}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};
