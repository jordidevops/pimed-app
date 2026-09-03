"use client";

import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { Menu, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { cn } from "@/lib/utils";
import { usePortalEmployee } from "../hooks/usePortalEmployee";
import { PortalSidebarNav } from "./PortalSidebarNav";
import { EmployeePortalFooter } from "./EmployeePortalFooter";
import { EmployeeCookieNotice } from "./EmployeeCookieNotice";

interface PortalShellProps {
  children: React.ReactNode;
}

function EmployeeIdentity({
  name,
  loading,
  compact,
}: {
  name: string | null;
  loading: boolean;
  compact?: boolean;
}) {
  const { t } = useTranslation("portal");

  return (
    <div className={cn("min-w-0", compact ? "flex-1" : "")}>
      <p className="text-muted-foreground text-xs font-medium uppercase tracking-wide">
        {t("employee_portal.portal_title", "Portal empleat")}
      </p>
      {loading && !name ? (
        <div className="bg-muted mt-1 h-6 w-40 max-w-full animate-pulse rounded-md" />
      ) : (
        <p className={cn("truncate font-semibold text-foreground", compact ? "text-base" : "text-lg")}>
          {name ?? "—"}
        </p>
      )}
    </div>
  );
}

export function PortalShell({ children }: PortalShellProps) {
  const { t } = useTranslation("portal");
  const pathname = usePathname();
  const employee = usePortalEmployee();
  const [mobileOpen, setMobileOpen] = useState(false);

  useEffect(() => {
    if (!mobileOpen) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = prev;
    };
  }, [mobileOpen]);

  useEffect(() => {
    setMobileOpen(false);
  }, [pathname]);

  const displayName = employee?.full_name ?? null;

  return (
    <div className="flex min-h-dvh w-full overflow-x-hidden bg-background text-base text-foreground">
      {/* Desktop sidebar */}
      <aside className="bg-card hidden w-60 shrink-0 flex-col border-r md:flex">
        <div className="border-b px-4 py-4">
          <EmployeeIdentity name={displayName} loading={!displayName} />
        </div>
        <div className="flex-1 overflow-y-auto py-2">
          <PortalSidebarNav />
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        {/* Mobile header */}
        <header className="bg-background/95 supports-[backdrop-filter]:bg-background/80 sticky top-0 z-40 border-b backdrop-blur md:hidden">
          <div className="flex items-center gap-3 px-4 py-3">
            <button
              type="button"
              className="hover:bg-muted inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-lg border"
              aria-expanded={mobileOpen}
              aria-controls="portal-mobile-nav"
              aria-label={
                mobileOpen
                  ? t("employee_portal.close_menu", "Tancar menú")
                  : t("employee_portal.open_menu", "Obrir menú")
              }
              onClick={() => setMobileOpen((o) => !o)}
            >
              {mobileOpen ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
            </button>
            <EmployeeIdentity name={displayName} loading={!displayName} compact />
          </div>
        </header>

        <main className="w-full min-w-0 flex-1">
          <div className="mx-auto w-full max-w-lg px-4 py-5 sm:px-5 md:max-w-2xl md:py-6">
            {children}
            <EmployeePortalFooter />
          </div>
        </main>
      </div>

      <EmployeeCookieNotice />

      {/* Mobile drawer */}
      {mobileOpen && (
        <>
          <button
            type="button"
            className="fixed inset-0 z-50 bg-black/45 md:hidden"
            aria-label={t("employee_portal.close_menu", "Tancar menú")}
            onClick={() => setMobileOpen(false)}
          />
          <aside
            id="portal-mobile-nav"
            className="bg-card fixed inset-y-0 left-0 z-50 flex w-[min(18.5rem,88vw)] flex-col border-r shadow-xl md:hidden"
          >
            <div className="flex items-start justify-between gap-2 border-b px-4 py-4">
              <EmployeeIdentity name={displayName} loading={!displayName} />
              <button
                type="button"
                className="hover:bg-muted inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-lg"
                onClick={() => setMobileOpen(false)}
                aria-label={t("employee_portal.close_menu", "Tancar menú")}
              >
                <X className="h-5 w-5" />
              </button>
            </div>
            <div className="flex-1 overflow-y-auto">
              <PortalSidebarNav onNavigate={() => setMobileOpen(false)} />
            </div>
          </aside>
        </>
      )}
    </div>
  );
}
