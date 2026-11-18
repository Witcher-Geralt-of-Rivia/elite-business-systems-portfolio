/**
 * "Forgot password" for this deployment: there is no email service, so recovery is handled by an
 * administrator, who issues a one-time reset link from the team page (Settings → Users).
 */
import { useTranslate } from "ra-core";
import { Link } from "react-router";
import { Layout } from "@/components/auth/layout";

export const ForgotPasswordPage = () => {
  const translate = useTranslate();
  return (
    <Layout>
      <div className="flex flex-col space-y-4 text-center">
        <h1 className="text-2xl font-semibold tracking-tight">
          {translate("crm.auth.forgot_password", { _: "Forgot your password?" })}
        </h1>
        <p className="text-sm text-muted-foreground">
          {translate("crm.auth.forgot_password_details", {
            _: "Ask an administrator of this CRM for a password reset link. The link is valid for one hour and can be used once.",
          })}
        </p>
        <Link to="/login" className="text-sm underline">
          {translate("crm.auth.back_to_login", { _: "Back to sign in" })}
        </Link>
      </div>
    </Layout>
  );
};

ForgotPasswordPage.path = "forgot-password";
