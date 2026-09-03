"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useTranslation } from "react-i18next";
import {
  CheckCircle2,
  ExternalLink,
  FileText,
  Loader2,
  PenLine,
  ShieldCheck,
} from "lucide-react";
import {
  acknowledgePortalDocument,
  fetchPortalDocuments,
  PortalApiError,
  type PortalDocumentsResponse,
} from "../api/portalApi";

export function PortalDocumentsPage() {
  const { t } = useTranslation("portal");
  const router = useRouter();
  const [data, setData] = useState<PortalDocumentsResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [ackingId, setAckingId] = useState<string | null>(null);
  const [ackChecked, setAckChecked] = useState<Record<string, boolean>>({});

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const docs = await fetchPortalDocuments();
      setData(docs);
    } catch (err) {
      if (
        err instanceof PortalApiError &&
        ["missing_session", "session_expired", "token_revoked"].includes(err.code)
      ) {
        router.replace("/portal/expired");
        return;
      }
      setError(t("employee_portal.documents.error_load", "No s'han pogut carregar els documents"));
    } finally {
      setLoading(false);
    }
  }, [router, t]);

  useEffect(() => {
    void load();
  }, [load]);

  async function handleAcknowledge(assignmentId: string) {
    setAckingId(assignmentId);
    try {
      await acknowledgePortalDocument(assignmentId);
      await load();
    } catch {
      setError(t("employee_portal.documents.error_ack", "No s'ha pogut confirmar la lectura"));
    } finally {
      setAckingId(null);
    }
  }

  const documents = data?.documents ?? [];
  const hasPending = documents.some((d) => d.is_pending);

  return (
    <div className="flex w-full flex-col gap-6 pb-8">
      <div>
        <h1 className="text-xl font-semibold">
          {t("employee_portal.documents.title", "Documents")}
        </h1>
        <p className="text-sm text-muted-foreground">
          {t(
            "employee_portal.documents.subtitle",
            "Protocols i documents que l'empresa t'ha assignat.",
          )}
        </p>
      </div>

      {hasPending && data?.settings.required_before_punch && (
        <div className="rounded-lg border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900">
          {t(
            "employee_portal.documents.punch_blocked_hint",
            "Has de llegir i confirmar el protocol abans de poder fitxar.",
          )}{" "}
          <Link href="/portal/punch" className="underline">
            {t("employee_portal.nav_punch", "Fitxatge")}
          </Link>
        </div>
      )}

      {loading ? (
        <div className="flex justify-center py-16 text-muted-foreground">
          <Loader2 className="h-6 w-6 animate-spin" />
        </div>
      ) : error ? (
        <p className="rounded-lg border border-destructive/30 bg-destructive/5 px-4 py-8 text-center text-sm text-destructive">
          {error}
        </p>
      ) : documents.length === 0 ? (
        <p className="rounded-lg border bg-muted/30 px-4 py-8 text-center text-sm text-muted-foreground">
          {t("employee_portal.documents.empty", "Cap document assignat")}
        </p>
      ) : (
        <ul className="space-y-4">
          {documents.map((doc) => {
            const done = !doc.is_pending;
            return (
              <li key={doc.id} className="rounded-xl border bg-card p-4 shadow-sm">
                <div className="flex items-start justify-between gap-3">
                  <div className="flex items-start gap-2">
                    <FileText className="mt-0.5 h-5 w-5 text-muted-foreground" />
                    <div>
                      <p className="font-medium">{doc.title}</p>
                      <p className="text-xs text-muted-foreground">
                        {t("employee_portal.documents.published", "Publicat")}:{" "}
                        {new Date(doc.published_at).toLocaleDateString("ca-ES")}
                      </p>
                    </div>
                  </div>
                  {done ? (
                    <span className="inline-flex items-center gap-1 text-xs font-medium text-emerald-700">
                      <CheckCircle2 className="h-4 w-4" />
                      {doc.signature_completed
                        ? t("employee_portal.documents.status_signed", "Signat")
                        : t("employee_portal.documents.status_ack", "Llegit")}
                    </span>
                  ) : (
                    <span className="text-xs font-medium text-amber-700">
                      {t("employee_portal.documents.status_pending", "Pendent")}
                    </span>
                  )}
                </div>

                {doc.view_url && (
                  <a
                    href={doc.view_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="mt-3 inline-flex items-center gap-1 text-sm text-primary underline"
                  >
                    {t("employee_portal.documents.open", "Obrir document")}
                    <ExternalLink className="h-3.5 w-3.5" />
                  </a>
                )}

                {!done && doc.requires_signature && doc.employee_sign_url && (
                  <a
                    href={doc.employee_sign_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="mt-3 flex w-full items-center justify-center gap-2 rounded-lg bg-violet-600 px-4 py-2.5 text-sm font-medium text-white"
                  >
                    <PenLine className="h-4 w-4" />
                    {t("employee_portal.documents.sign", "Signar document")}
                  </a>
                )}

                {!done && !doc.requires_signature && (
                  <div className="mt-4 space-y-3 rounded-lg bg-muted/30 p-3">
                    <label className="flex items-start gap-2 text-sm">
                      <input
                        type="checkbox"
                        className="mt-1"
                        checked={ackChecked[doc.id] ?? false}
                        onChange={(e) =>
                          setAckChecked((prev) => ({ ...prev, [doc.id]: e.target.checked }))
                        }
                      />
                      <span>
                        {t(
                          "employee_portal.documents.ack_label",
                          "He llegit i entenc com es calculen les meves hores de treball.",
                        )}
                      </span>
                    </label>
                    <button
                      type="button"
                      disabled={!ackChecked[doc.id] || ackingId === doc.id}
                      onClick={() => void handleAcknowledge(doc.id)}
                      className="flex w-full items-center justify-center gap-2 rounded-lg bg-primary px-4 py-2.5 text-sm font-medium text-primary-foreground disabled:opacity-50"
                    >
                      {ackingId === doc.id ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <ShieldCheck className="h-4 w-4" />
                      )}
                      {t("employee_portal.documents.confirm_read", "Confirmar lectura")}
                    </button>
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}

      {!loading && !error && hasPending && (
        <p className="text-center text-xs text-muted-foreground">
          <Link href="/portal/punch" className="underline">
            {t("employee_portal.nav_punch", "Tornar al fitxatge")}
          </Link>
        </p>
      )}
    </div>
  );
}
