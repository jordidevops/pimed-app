"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useTranslation } from "react-i18next";
import { FileText, Loader2, Megaphone, Pin } from "lucide-react";
import {
  fetchPortalContent,
  PortalApiError,
  type PortalContentListItem,
} from "../api/portalApi";
import { usePortalEmployee } from "../hooks/usePortalEmployee";
import {
  isPortalContentUnread,
  markAllPortalContentRead,
} from "../utils/portalContentReadState";

const NEW_CONTENT_DAYS = 7;

function isRecent(publishedAt: string | null): boolean {
  if (!publishedAt) return false;
  const published = new Date(publishedAt).getTime();
  if (Number.isNaN(published)) return false;
  return Date.now() - published <= NEW_CONTENT_DAYS * 24 * 60 * 60 * 1000;
}

function formatPublishedDate(value: string | null, locale: string): string {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleDateString(locale, {
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

function contentTypeIcon(contentType: string) {
  return contentType === "page" ? FileText : Megaphone;
}

export function PortalNewsPage() {
  const { t, i18n } = useTranslation("portal");
  const router = useRouter();
  const employee = usePortalEmployee();
  const [items, setItems] = useState<PortalContentListItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await fetchPortalContent();
      setItems(data.items);
      if (employee?.id && employee.tenant_id) {
        markAllPortalContentRead(data.items, employee.tenant_id, employee.id);
      }
    } catch (err) {
      if (
        err instanceof PortalApiError &&
        ["missing_session", "session_expired", "token_revoked"].includes(err.code)
      ) {
        router.replace("/portal/expired");
        return;
      }
      if (err instanceof PortalApiError && err.code === "content_module_disabled") {
        router.replace("/portal/punch");
        return;
      }
      setError(t("employee_portal.news.error_load", "No s'han pogut carregar les notícies"));
    } finally {
      setLoading(false);
    }
  }, [employee?.id, employee?.tenant_id, router, t]);

  useEffect(() => {
    void load();
  }, [load]);

  return (
    <div className="flex w-full flex-col gap-6 pb-8">
      <div>
        <h1 className="text-xl font-semibold">
          {t("employee_portal.news.title", "Notícies")}
        </h1>
        <p className="text-sm text-muted-foreground">
          {t(
            "employee_portal.news.subtitle",
            "Anuncis, pàgines i comunicacions internes de l'empresa.",
          )}
        </p>
      </div>

      {loading ? (
        <div className="flex justify-center py-16 text-muted-foreground">
          <Loader2 className="h-6 w-6 animate-spin" />
        </div>
      ) : error ? (
        <p className="rounded-lg border border-destructive/30 bg-destructive/5 px-4 py-8 text-center text-sm text-destructive">
          {error}
        </p>
      ) : items.length === 0 ? (
        <p className="rounded-lg border bg-muted/30 px-4 py-8 text-center text-sm text-muted-foreground">
          {t("employee_portal.news.empty", "Cap contingut publicat")}
        </p>
      ) : (
        <ul className="space-y-3">
          {items.map((item) => {
            const recent = isRecent(item.published_at);
            const unread =
              employee?.id && employee.tenant_id
                ? isPortalContentUnread(item, employee.tenant_id, employee.id)
                : false;
            const TypeIcon = contentTypeIcon(item.content_type);
            const typeLabel =
              item.content_type === "page"
                ? t("employee_portal.news.type_page", "Pàgina")
                : t("employee_portal.news.type_announcement", "Anunci");

            return (
              <li key={item.id}>
                <Link
                  href={`/portal/news/${encodeURIComponent(item.slug)}`}
                  className={`block rounded-xl border bg-card p-4 shadow-sm transition hover:border-primary/40 ${
                    unread ? "border-primary/25" : ""
                  }`}
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <div className="mb-1 flex flex-wrap items-center gap-2">
                        <span className="inline-flex items-center gap-1 rounded-full bg-muted px-2 py-0.5 text-xs font-medium text-muted-foreground">
                          <TypeIcon className="h-3 w-3" aria-hidden />
                          {typeLabel}
                        </span>
                        {item.is_sticky ? (
                          <span className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-900">
                            <Pin className="h-3 w-3" />
                            {t("employee_portal.news.sticky_badge", "Destacat")}
                          </span>
                        ) : null}
                        {recent ? (
                          <span className="rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">
                            {t("employee_portal.news.new_badge", "Nou")}
                          </span>
                        ) : null}
                        {unread ? (
                          <span className="rounded-full bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-800">
                            {t("employee_portal.news.unread_badge_short", "Sense llegir")}
                          </span>
                        ) : null}
                      </div>
                      <p className={`leading-snug ${unread ? "font-semibold" : "font-medium"}`}>
                        {item.title}
                      </p>
                      {item.excerpt ? (
                        <p className="mt-1 line-clamp-2 text-sm text-muted-foreground">
                          {item.excerpt}
                        </p>
                      ) : null}
                      {item.published_at ? (
                        <p className="mt-2 text-xs text-muted-foreground">
                          {formatPublishedDate(item.published_at, i18n.language || "ca")}
                        </p>
                      ) : null}
                    </div>
                    <TypeIcon className="mt-0.5 h-5 w-5 shrink-0 text-muted-foreground" aria-hidden />
                  </div>
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
