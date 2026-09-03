"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { useTranslation } from "react-i18next";
import { ArrowLeft, Loader2 } from "lucide-react";
import { sanitizePortalHtml } from "@/lib/sanitizePortalHtml";
import {
  fetchPortalContentBySlug,
  PortalApiError,
  type PortalContentDetail,
} from "../api/portalApi";
import { usePortalEmployee } from "../hooks/usePortalEmployee";
import { markPortalContentSlugRead } from "../utils/portalContentReadState";

function extractHtml(content: PortalContentDetail["content"]): string {
  if (!content || typeof content !== "object") return "";
  if ("html" in content && typeof content.html === "string") {
    return content.html;
  }
  return "";
}

export function PortalNewsDetailPage() {
  const { t } = useTranslation("portal");
  const router = useRouter();
  const employee = usePortalEmployee();
  const params = useParams<{ slug: string }>();
  const slug = params.slug ? decodeURIComponent(params.slug) : "";
  const [item, setItem] = useState<PortalContentDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!slug) return;
    setLoading(true);
    setError(null);
    try {
      const data = await fetchPortalContentBySlug(slug);
      setItem(data);
      if (employee?.id && employee.tenant_id) {
        markPortalContentSlugRead(employee.tenant_id, employee.id, data.slug, data.published_at);
      }
    } catch (err) {
      if (
        err instanceof PortalApiError &&
        ["missing_session", "session_expired", "token_revoked"].includes(err.code)
      ) {
        router.replace("/portal/expired");
        return;
      }
      if (err instanceof PortalApiError && err.code === "content_not_found") {
        setError(t("employee_portal.news.not_found", "Notícia no trobada"));
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
  }, [employee?.id, employee?.tenant_id, router, slug, t]);

  useEffect(() => {
    void load();
  }, [load]);

  const html = sanitizePortalHtml(extractHtml(item?.content ?? null));

  return (
    <div className="flex w-full flex-col gap-6 pb-8">
      <Link
        href="/portal/news"
        className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-primary"
      >
        <ArrowLeft className="h-4 w-4" />
        {t("employee_portal.news.back", "Tornar a notícies")}
      </Link>

      {loading ? (
        <div className="flex justify-center py-16 text-muted-foreground">
          <Loader2 className="h-6 w-6 animate-spin" />
        </div>
      ) : error ? (
        <p className="rounded-lg border border-destructive/30 bg-destructive/5 px-4 py-8 text-center text-sm text-destructive">
          {error}
        </p>
      ) : item ? (
        <article className="space-y-4">
          <header>
            <p className="text-xs font-medium text-muted-foreground mb-1">
              {item.content_type === "page"
                ? t("employee_portal.news.type_page", "Pàgina")
                : t("employee_portal.news.type_announcement", "Anunci")}
            </p>
            <h1 className="text-xl font-semibold leading-snug">{item.title}</h1>
            {item.published_at ? (
              <p className="mt-2 text-sm text-muted-foreground">
                {new Date(item.published_at).toLocaleDateString(undefined, {
                  day: "numeric",
                  month: "long",
                  year: "numeric",
                })}
              </p>
            ) : null}
          </header>
          {html ? (
            <div
              className="prose prose-neutral max-w-none space-y-3 text-sm leading-relaxed"
              dangerouslySetInnerHTML={{ __html: html }}
            />
          ) : (
            <p className="text-sm text-muted-foreground">
              {t("employee_portal.news.no_body", "Aquesta notícia no té contingut.")}
            </p>
          )}
        </article>
      ) : null}
    </div>
  );
}
