/**
 * Sets a password from a one-time invitation / reset link (#/set-password?token=...).
 * Replaces the Supabase version (which exchanged Supabase access/refresh tokens).
 */
import { useState } from "react";
import { Form, required, useNotify, useTranslate } from "ra-core";
import { useNavigate, useSearchParams } from "react-router";
import { Button } from "@/components/ui/button";
import { TextInput } from "@/components/admin/text-input";
import { Layout } from "@/components/auth/layout";
import { apiFetch } from "@/components/atomic-crm/providers/portfolio/http";

interface SetPasswordFormData {
  password: string;
  confirmPassword: string;
}

export const SetPasswordPage = () => {
  const [loading, setLoading] = useState(false);
  const [params] = useSearchParams();
  const token = params.get("token");
  const notify = useNotify();
  const translate = useTranslate();
  const navigate = useNavigate();

  const validate = (values: SetPasswordFormData) => {
    if (values.password !== values.confirmPassword) {
      const msg = translate("crm.auth.password_mismatch", { _: "Passwords do not match" });
      return { password: msg, confirmPassword: msg };
    }
    return {};
  };

  if (!token) {
    return (
      <Layout>
        <p>{translate("crm.auth.missing_token", { _: "This page needs the one-time link you received. Ask an administrator for a new link." })}</p>
      </Layout>
    );
  }

  const submit = async (values: SetPasswordFormData) => {
    setLoading(true);
    try {
      await apiFetch("/auth/set-password", { method: "POST", body: { token, password: values.password } });
      notify("crm.auth.password_set", { type: "success", messageArgs: { _: "Password saved. Please sign in." } });
      navigate("/login");
    } catch (error) {
      notify((error as Error).message, { type: "warning" });
    } finally {
      setLoading(false);
    }
  };

  return (
    <Layout>
      <div className="flex flex-col space-y-2 text-center">
        <h1 className="text-2xl font-semibold tracking-tight">
          {translate("crm.auth.choose_password", { _: "Choose your password" })}
        </h1>
        <p className="text-sm text-muted-foreground">
          {translate("crm.auth.password_rules", { _: "At least 12 characters." })}
        </p>
      </div>
      <Form className="space-y-8" onSubmit={submit as any} validate={validate as any}>
        <TextInput
          label={translate("ra.auth.password", { _: "Password" })}
          autoComplete="new-password"
          source="password"
          type="password"
          validate={required()}
        />
        <TextInput
          label={translate("crm.auth.confirm_password", { _: "Confirm password" })}
          autoComplete="new-password"
          source="confirmPassword"
          type="password"
          validate={required()}
        />
        <Button type="submit" className="cursor-pointer" disabled={loading}>
          {translate("ra.action.save")}
        </Button>
      </Form>
    </Layout>
  );
};

SetPasswordPage.path = "set-password";
