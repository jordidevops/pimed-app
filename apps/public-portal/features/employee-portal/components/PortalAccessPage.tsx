"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  fetchPortalAccessLogs,
  PortalAccessLogRow,
  PortalApiError,
  PortalPeriodConfirmationRow,
} from "../api/portalApi";
import {
  formatPortalPeriodRange,
  periodRangeFromMetadata,
} from "../utils/portalAccessUtils";
import { portalAccessLogActionLabel } from "../utils/portalAccessLogLabels";

function cycleTypeLabel(
  cycleType: string,
  t: (key: string, fallback: string) => string,
): string {
  if (cycleType === "iso_week") {
    return t("employee_portal.access.cycle_iso_week", "Setmana ISO");
  }
  if (cycleType === "calendar_month") {
    return t("employee_portal.access.cycle_calendar_month", "Mes natural");
  }
  return cycleType;
}

function logDetail(
  log: PortalAccessLogRow,
  locale: string,
  t: (key: string, fallback: string) => string,
): string | null {
  const range = periodRangeFromMetadata(log.metadata);
  if (range) {
    return formatPortalPeriodRange(range.from, range.to, locale);
  }
  return null;
}

export function PortalAccessPage() {
  const { t, i18n } = useTranslation("portal");
  const locale = i18n.language === "en" ? "en-GB" : i18n.language === "es" ? "es-ES" : "ca-ES";

  const [logs, setLogs] = useState<PortalAccessLogRow[]>([]);
  const [confirmations, setConfirmations] = useState<PortalPeriodConfirmationRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setError(null);
    try {
      const data = await fetchPortalAccessLogs();
      setLogs(data.logs);
      setConfirmations(data.period_confirmations);
    } catch (err) {
      setError(err instanceof PortalApiError ? err.code : "load_failed");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  if (loading) {
    return (
      <p className="text-muted-foreground py-16 text-center text-sm">
        {t("employee_portal.loading", "Carregant…")}
      </p>
    );
  }

  const hasContent = logs.length > 0 || confirmations.length > 0;

  return (
    <div className="flex w-full flex-col gap-6">
      <div>
        <h1 className="text-xl font-semibold">
          {t("employee_portal.access.title", "Els meus accessos")}
        </h1>
        <p className="text-muted-foreground text-sm">
          {t(
            "employee_portal.access.subtitle",
            "Registre d'activitat del teu enllaç personal (transparència i seguretat)",
          )}
        </p>
      </div>

      {error && (
        <p className="text-destructive text-sm" role="alert">
          {error}
        </p>
      )}

      {confirmations.length > 0 && (
        <section className="space-y-2">
          <h2 className="text-base font-semibold">
            {t("employee_portal.access.confirmations_title", "Confirmacions de registre")}
          </h2>
          <p className="text-muted-foreground text-xs">
            {t(
              "employee_portal.access.confirmations_hint",
              "Períodes que has confirmat des d'aquest portal (no és una signatura electrònica).",
            )}
          </p>
          <ul className="divide-y rounded-lg border">
            {confirmations.map((row) => (
              <li key={row.id} className="px-4 py-3 text-sm">
                <p className="font-medium">
                  {formatPortalPeriodRange(row.period_from, row.period_to, locale)}
                </p>
                <p className="text-muted-foreground text-xs">
                  {cycleTypeLabel(row.cycle_type, t)}
                  {" · "}
                  {new Date(row.confirmed_at).toLocaleString(locale, {
                    dateStyle: "medium",
                    timeStyle: "short",
                  })}
                </p>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section className="space-y-2">
        <h2 className="text-base font-semibold">
          {t("employee_portal.access.activity_title", "Activitat recent")}
        </h2>

        {!hasContent ? (
          <p className="text-muted-foreground py-8 text-center text-sm">
            {t("employee_portal.access.empty", "Encara no hi ha accessos registrats")}
          </p>
        ) : logs.length === 0 ? (
          <p className="text-muted-foreground py-4 text-center text-sm">
            {t("employee_portal.access.logs_empty", "Encara no hi ha activitat registrada")}
          </p>
        ) : (
          <ul className="divide-y rounded-lg border">
            {logs.map((log) => {
              const detail = logDetail(log, locale, t);
              return (
                <li key={log.id} className="px-4 py-3 text-sm">
                  <div className="flex items-start justify-between gap-2">
                    <div>
                      <p className="font-medium">{portalAccessLogActionLabel(log.action, t)}</p>
                      {detail ? (
                        <p className="text-muted-foreground text-xs">{detail}</p>
                      ) : null}
                      <p className="text-muted-foreground text-xs">
                        {new Date(log.accessed_at).toLocaleString(locale, {
                          dateStyle: "medium",
                          timeStyle: "short",
                        })}
                        {log.ip_address ? ` · ${log.ip_address}` : ""}
                      </p>
                    </div>
                    {log.http_status != null && log.http_status >= 400 && (
                      <span className="text-destructive text-xs">{log.http_status}</span>
                    )}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
