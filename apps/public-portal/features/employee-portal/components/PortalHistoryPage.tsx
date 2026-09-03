"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { useTranslation } from "react-i18next";
import { ChevronLeft, ChevronRight, Loader2 } from "lucide-react";
import {
  fetchPortalHistory,
  PortalApiError,
  type PortalHistoryDay,
} from "../api/portalApi";
import {
  canNavigateHistoryNext,
  canNavigateHistoryPrev,
  clampHistoryRange,
  formatHistoryTime,
  formatNetMinutes,
  getHistoryRangeForMode,
  HISTORY_STATUS_CLASS,
  navigateHistory,
  PORTAL_HISTORY_DAYS,
  type PortalHistoryViewMode,
} from "../utils/portalHistoryUtils";

function statusLabelKey(status: string): string {
  if (status === "open") return "employee_portal.history.status_open";
  if (status === "closed") return "employee_portal.history.status_closed";
  if (status === "adjusted") return "employee_portal.history.status_adjusted";
  if (status === "missing") return "employee_portal.history.status_missing";
  if (status === "approved") return "employee_portal.history.status_approved";
  if (status === "anomaly") return "employee_portal.history.status_anomaly";
  return "employee_portal.history.status_open";
}

const STATUS_FALLBACKS: Record<string, string> = {
  open: "Obert",
  closed: "Tancat",
  adjusted: "Ajustat",
  missing: "Sense dades",
  approved: "Aprovat",
  anomaly: "Anomalia",
};

export function PortalHistoryPage() {
  const { t, i18n } = useTranslation("portal");
  const router = useRouter();

  const [mode, setMode] = useState<PortalHistoryViewMode>("week");
  const [refDate, setRefDate] = useState(() => new Date());
  const [days, setDays] = useState<PortalHistoryDay[]>([]);
  const [totalNetMinutes, setTotalNetMinutes] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const dateLocale =
    i18n.language === "en" ? "en-GB" : i18n.language === "es" ? "es-ES" : "ca-ES";

  const { from, to, label } = useMemo(
    () => getHistoryRangeForMode(mode, refDate, dateLocale),
    [mode, refDate, dateLocale],
  );

  const clampedRange = useMemo(() => clampHistoryRange(from, to), [from, to]);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await fetchPortalHistory(clampedRange.from, clampedRange.to);
      setDays(data.days ?? []);
      setTotalNetMinutes(data.total_net_minutes ?? 0);
    } catch (err) {
      if (
        err instanceof PortalApiError &&
        ["missing_session", "session_expired", "token_revoked"].includes(err.code)
      ) {
        router.replace("/portal/expired");
        return;
      }
      setError(
        err instanceof PortalApiError
          ? t("employee_portal.history.error_load_failed", "No s'ha pogut carregar l'historial")
          : t("employee_portal.history.error_load_failed", "No s'ha pogut carregar l'historial"),
      );
    } finally {
      setLoading(false);
    }
  }, [clampedRange.from, clampedRange.to, router, t]);

  useEffect(() => {
    void load();
  }, [load]);

  const canPrev = canNavigateHistoryPrev(mode, refDate);
  const canNext = canNavigateHistoryNext(mode, refDate);

  const totalHours = Math.floor(totalNetMinutes / 60);
  const totalMins = totalNetMinutes % 60;

  return (
    <div className="flex w-full flex-col gap-4">
      <div>
        <h1 className="text-lg font-semibold">
          {t("employee_portal.history.title", "Historial de fitxatges")}
        </h1>
        <p className="text-muted-foreground mt-0.5 text-xs">
          {t("employee_portal.history.window_hint", "Últims {{days}} dies (només lectura)", {
            days: PORTAL_HISTORY_DAYS,
          })}
        </p>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <div className="flex rounded-lg border p-0.5">
          {(["day", "week", "month"] as const).map((m) => (
            <button
              key={m}
              type="button"
              className={`rounded-md px-3 py-1 text-xs font-medium transition ${
                mode === m
                  ? "bg-primary text-primary-foreground"
                  : "text-muted-foreground hover:bg-muted"
              }`}
              onClick={() => setMode(m)}
            >
              {m === "day"
                ? t("employee_portal.history.filter_day", "Dia")
                : m === "week"
                  ? t("employee_portal.history.filter_week", "Setmana")
                  : t("employee_portal.history.filter_month", "Mes")}
            </button>
          ))}
        </div>

        <div className="ml-auto flex items-center gap-1">
          <button
            type="button"
            disabled={!canPrev}
            onClick={() => canPrev && setRefDate((d) => navigateHistory(mode, d, -1))}
            className="rounded-lg border p-2 hover:bg-muted disabled:cursor-not-allowed disabled:opacity-40"
            aria-label={t("employee_portal.history.nav_prev", "Anterior")}
          >
            <ChevronLeft className="h-5 w-5" />
          </button>
          <span className="min-w-[9rem] text-center text-sm font-medium capitalize">{label}</span>
          <button
            type="button"
            disabled={!canNext}
            onClick={() => canNext && setRefDate((d) => navigateHistory(mode, d, 1))}
            className="rounded-lg border p-2 hover:bg-muted disabled:cursor-not-allowed disabled:opacity-40"
            aria-label={t("employee_portal.history.nav_next", "Següent")}
          >
            <ChevronRight className="h-5 w-5" />
          </button>
        </div>
      </div>

      {!loading && days.length > 0 && (
        <div className="rounded-lg border bg-primary/5 px-4 py-3">
          <p className="text-primary text-sm font-semibold">
            {t("employee_portal.history.total_hours", "Total: {{hours}}h {{minutes}}m", {
              hours: totalHours,
              minutes: totalMins,
            })}
          </p>
        </div>
      )}

      {loading && (
        <div className="text-muted-foreground flex items-center justify-center gap-2 py-8 text-sm">
          <Loader2 className="h-4 w-4 animate-spin" />
          {t("employee_portal.history.loading", "Carregant historial…")}
        </div>
      )}

      {error && !loading && (
        <p className="text-destructive text-center text-sm" role="alert">
          {error}
        </p>
      )}

      {!loading && !error && days.length === 0 && (
        <p className="text-muted-foreground py-8 text-center text-sm">
          {t("employee_portal.history.empty", "Cap registre per al període seleccionat")}
        </p>
      )}

      {!loading && !error && days.length > 0 && (
        <div className="overflow-hidden rounded-lg border">
          <table className="w-full text-sm">
            <thead className="bg-muted/30">
              <tr>
                <th className="px-3 py-2 text-left text-xs font-semibold text-muted-foreground">
                  {t("employee_portal.history.work_date", "Data")}
                </th>
                <th className="px-3 py-2 text-left text-xs font-semibold text-muted-foreground">
                  {t("employee_portal.history.starts_at", "Entrada")}
                </th>
                <th className="px-3 py-2 text-left text-xs font-semibold text-muted-foreground">
                  {t("employee_portal.history.ends_at", "Sortida")}
                </th>
                <th className="hidden px-3 py-2 text-right text-xs font-semibold text-muted-foreground sm:table-cell">
                  {t("employee_portal.history.net_hours", "Hores")}
                </th>
                <th className="px-3 py-2 text-center text-xs font-semibold text-muted-foreground">
                  {t("employee_portal.history.status", "Estat")}
                </th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {days.map((entry) => {
                const { hours, mins } = formatNetMinutes(entry.net_minutes);
                const status = entry.status ?? "open";
                return (
                  <tr key={entry.id} className="hover:bg-muted/20">
                    <td className="px-3 py-2.5 font-medium">
                      {entry.work_date
                        ? new Date(`${entry.work_date}T12:00:00`).toLocaleDateString(dateLocale, {
                            weekday: "short",
                            day: "numeric",
                            month: "short",
                          })
                        : "—"}
                    </td>
                    <td className="px-3 py-2.5 tabular-nums">
                      {formatHistoryTime(entry.starts_at, dateLocale)}
                    </td>
                    <td className="px-3 py-2.5 tabular-nums">
                      {formatHistoryTime(entry.ends_at, dateLocale)}
                    </td>
                    <td className="hidden px-3 py-2.5 text-right tabular-nums font-medium sm:table-cell">
                      {t("employee_portal.history.hours_minutes", "{{hours}}h {{minutes}}m", {
                        hours,
                        minutes: mins,
                      })}
                    </td>
                    <td className="px-3 py-2.5 text-center">
                      <span
                        className={`inline-block rounded-full px-2 py-0.5 text-[10px] font-medium sm:text-xs ${
                          HISTORY_STATUS_CLASS[status] ?? HISTORY_STATUS_CLASS.open
                        }`}
                      >
                        {t(statusLabelKey(status), STATUS_FALLBACKS[status] ?? status)}
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
