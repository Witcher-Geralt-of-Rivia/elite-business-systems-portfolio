import type { ComponentType, ReactNode } from "react";
import { LiveUpdates } from "./LiveUpdates";
import { OneTimeLinkDialog } from "./OneTimeLinkDialog";

/** Wraps an upstream layout so every authenticated page gets live updates and the link dialog. */
export function withPortfolioServices(Layout: ComponentType<{ children: ReactNode }>) {
  const PortfolioLayout = ({ children }: { children: ReactNode }) => (
    <>
      <Layout>{children}</Layout>
      <LiveUpdates />
      <OneTimeLinkDialog />
    </>
  );
  PortfolioLayout.displayName = `withPortfolioServices(${Layout.displayName ?? Layout.name ?? "Layout"})`;
  return PortfolioLayout;
}
