"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useTranslation } from "react-i18next";
import { cn } from "@/lib/utils";
import { PORTAL_NAV_ITEMS } from "../config/portalNavConfig";
import { usePortalContentModuleEnabled } from "../hooks/usePortalContentModuleEnabled";
import { usePortalContentUnreadCount } from "../hooks/usePortalContentUnreadCount";

interface PortalSidebarNavProps {
  onNavigate?: () => void;
  className?: string;
}

export function PortalSidebarNav({ onNavigate, className }: PortalSidebarNavProps) {
  const pathname = usePathname();
  const { t } = useTranslation("portal");
  const contentModuleEnabled = usePortalContentModuleEnabled();
  const unreadNewsCount = usePortalContentUnreadCount(contentModuleEnabled);

  const navItems = PORTAL_NAV_ITEMS.filter(
    (item) => !item.requiresContentModule || contentModuleEnabled,
  );

  return (
    <nav className={cn("flex flex-col gap-0.5 p-2", className)} aria-label="Navegació portal">
      {navItems.map((item) => {
        const active = pathname === item.href || pathname.startsWith(`${item.href}/`);
        const Icon = item.icon;
        const label = t(item.labelKey, item.labelFallback);
        const showUnreadBadge = item.href === "/portal/news" && unreadNewsCount > 0;

        return (
          <Link
            key={item.href}
            href={item.href}
            onClick={onNavigate}
            className={cn(
              "flex items-center gap-3 rounded-lg px-3 py-3 text-base font-medium transition",
              active
                ? "bg-primary text-primary-foreground"
                : "text-foreground hover:bg-muted",
            )}
          >
            <Icon className="h-5 w-5 shrink-0" aria-hidden />
            <span className="truncate flex-1">{label}</span>
            {showUnreadBadge ? (
              <span
                className={cn(
                  "inline-flex min-w-[1.25rem] h-5 items-center justify-center rounded-full px-1.5 text-xs font-semibold tabular-nums",
                  active ? "bg-primary-foreground text-primary" : "bg-primary text-primary-foreground",
                )}
                aria-label={t("employee_portal.news.unread_badge", "{{count}} sense llegir", {
                  count: unreadNewsCount,
                })}
              >
                {unreadNewsCount > 99 ? "99+" : unreadNewsCount}
              </span>
            ) : null}
          </Link>
        );
      })}
    </nav>
  );
}
