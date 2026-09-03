"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { useTranslation } from "react-i18next";
import {
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  ExternalLink,
  Loader2,
  PenLine,
} from "lucide-react";
import {
  confirmPortalMonthlyReport,
  confirmPortalPeriodReport,
  createEmptyCalendarDay,
  fetchPortalMonthlyReport,
  fetchPortalWeekReport,
  PortalApiError,
  type PortalMonthlyReportResponse,
} from "../api/portalApi";
import { PortalViewToggle } from "./PortalViewToggle";
import {
  buildWeekDisplayDays,
  defaultWeekIndexForMonth,
  filterDaysInRange,
  formatBalanceMinutes,
  formatHoursMinutes,
  formatMonthlyBlocker,
  formatTime,
  isMonthlyDayVisible,
  isPeriodConfirmed,
  isPeriodEnded,
  listIsoWeeksInMonth,
  monthLabel,
  monthlyDayTypeLabel,
  MONTHLY_STATUS_CLASS,
  navigateYearMonth,
  parseYearMonth,
  summarizeCalendarDays,
  weekRangeLabel,
  type RecordViewMode,
} from "../utils/portalMonthlyUtils";
import type { PortalMonthlyCalendarDay } from "../api/portalApi";

function statusLabelKey(status: string): string {
  return `employee_portal.monthly.status_${status}`;
}

const STATUS_FALLBACKS: Record<string, string> = {
  draft: "Esborrany",
  employee_confirmed: "Confirmat",
  manager_approved: "Tancat per nòmina",
  signed: "Signat",
  archived: "Arxivat",
};

type ConfirmSectionTone = "ready" | "completed" | "info" | "blocked";

interface ConfirmSectionState {
  enabled: boolean;
  tone: ConfirmSectionTone;
  reasons: string[];
}

export function PortalRecordPage() {
  const { t, i18n } = useTranslation("portal");
  const router = useRouter();
  const searchParams = useSearchParams();

  const initial = useMemo(() => parseYearMonth(searchParams), [searchParams]);
  const initialView = searchParams.get("view") === "week" ? "week" : "month";
  const [year, setYear] = useState(initial.year);
  const [month, setMonth] = useState(initial.month);
  const [recordView, setRecordView] = useState<RecordViewMode>(initialView);
  const [weekIndex, setWeekIndex] = useState(0);
  const [data, setData] = useState<PortalMonthlyReportResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [confirming, setConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [ackReviewed, setAckReviewed] = useState(false);
  const [confirmSuccess, setConfirmSuccess] = useState(false);
  const [showAllDays, setShowAllDays] = useState(false);

  const dateLocale =
    i18n.language === "en" ? "en-GB" : i18n.language === "es" ? "es-ES" : "ca-ES";

  const isoWeekMode = data?.settings.employee_confirm_cycle === "iso_week";
  const monthWeeks = useMemo(() => listIsoWeeksInMonth(year, month), [year, month]);
  const activeWeek = monthWeeks[weekIndex] ?? monthWeeks[0] ?? null;

  useEffect(() => {
    setWeekIndex(defaultWeekIndexForMonth(monthWeeks, year, month));
  }, [year, month, monthWeeks]);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    setConfirmSuccess(false);
    try {
      const periodArgs =
        recordView === "week" && activeWeek
          ? { from: activeWeek.from, to: activeWeek.to }
          : undefined;
      const report =
        recordView === "week" && activeWeek
          ? await fetchPortalWeekReport(year, month, activeWeek)
          : await fetchPortalMonthlyReport(
              year,
              month,
              periodArgs?.from,
              periodArgs?.to,
            );
      setData(report);
    } catch (err) {
      if (
        err instanceof PortalApiError &&
        ["missing_session", "session_expired", "token_revoked"].includes(err.code)
      ) {
        router.replace("/portal/expired");
        return;
      }
      setError(
        t("employee_portal.monthly.error_load_failed", "No s'ha pogut carregar el registre mensual"),
      );
    } finally {
      setLoading(false);
    }
  }, [year, month, recordView, activeWeek, router, t]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    if (data?.settings.employee_confirm_cycle !== "iso_week" && recordView === "week") {
      setRecordView("month");
    }
  }, [data?.settings.employee_confirm_cycle, recordView]);

  useEffect(() => {
    const params = new URLSearchParams({ year: String(year), month: String(month) });
    if (recordView === "week") params.set("view", "week");
    router.replace(`/portal/monthly?${params}`, { scroll: false });
  }, [year, month, recordView, router]);

  const status = data?.report.status ?? "draft";
  const summary = data?.summary;
  const calendarDays = data?.calendar_days ?? [];
  const settings = data?.settings;
  const validation = data?.validation;
  const periodValidation = data?.period_validation;
  const periodStatus = data?.period_status;
  const requireDigitalSignature = settings?.require_digital_signature ?? false;
  const signatureIsEmployeeApproval = settings?.signature_is_employee_approval ?? false;
  const employeeConfirmRequired = settings?.employee_confirm_required ?? true;

  const weekAlreadyConfirmed =
    activeWeek && periodStatus
      ? isPeriodConfirmed(periodStatus.confirmations, activeWeek.from, activeWeek.to)
      : false;

  const activeValidation = recordView === "week" ? periodValidation : validation;

  const canConfirmL1Month =
    !isoWeekMode &&
    !requireDigitalSignature &&
    !signatureIsEmployeeApproval &&
    status === "draft" &&
    (validation?.confirmable ?? false);

  const canConfirmL1Week =
    !requireDigitalSignature &&
    !signatureIsEmployeeApproval &&
    recordView === "week" &&
    !weekAlreadyConfirmed &&
    (periodValidation?.confirmable ?? false);

  const canConfirmL1 = recordView === "week" ? canConfirmL1Week : canConfirmL1Month;

  const showSignL2 =
    requireDigitalSignature &&
    !!data?.employee_sign_url &&
    (status === "manager_approved" || !!data?.report.signing_submission_id);

  const confirmButtonState = useMemo((): ConfirmSectionState | null => {
    if (!data) return null;

    if (status === "signed" || status === "archived") {
      return null;
    }

    if (requireDigitalSignature) {
      if (showSignL2) return null;
      return {
        enabled: false,
        tone: "info",
        reasons: [
          t(
            "employee_portal.monthly.confirm_disabled_l2",
            "La teva empresa requereix signatura digital. El gestor tancarà el mes i rebràs l'enllaç per signar.",
          ),
        ],
      };
    }

    if (signatureIsEmployeeApproval) {
      if (showSignL2) return null;
      if (status === "manager_approved") return null;
      return {
        enabled: false,
        tone: "info",
        reasons: [
          t(
            "employee_portal.monthly.confirm_disabled_via_signature",
            "No cal confirmar el registre manualment. El gestor tancarà el mes i la teva signatura del document comptarà com a confirmació.",
          ),
        ],
      };
    }

    if (
      recordView === "month" &&
      isoWeekMode &&
      status === "draft" &&
      !periodStatus?.month_fully_confirmed
    ) {
      return {
        enabled: false,
        tone: "info",
        reasons: [
          t(
            "employee_portal.record.confirm_use_week_tab",
            "Amb confirmació setmanal, revisa i confirma cada setmana des de la pestanya «Setmana».",
          ),
        ],
      };
    }

    if (canConfirmL1) {
      return { enabled: true, tone: "ready", reasons: [] };
    }

    if (status === "employee_confirmed" && recordView === "month") {
      return {
        enabled: false,
        tone: "completed",
        reasons: [
          t(
            "employee_portal.monthly.status_confirmed",
            "Has confirmat el registre. El gestor el revisarà i tancarà per nòmina.",
          ),
        ],
      };
    }

    if (recordView === "week" && weekAlreadyConfirmed) {
      return {
        enabled: false,
        tone: "completed",
        reasons: [
          t(
            "employee_portal.record.week_confirmed",
            "Has confirmat aquesta setmana. Continua amb les setmanes pendents del mes.",
          ),
        ],
      };
    }

    if (status === "employee_confirmed" && recordView === "week" && periodStatus?.month_fully_confirmed) {
      return {
        enabled: false,
        tone: "completed",
        reasons: [
          t(
            "employee_portal.record.month_fully_confirmed",
            "Totes les setmanes del mes estan confirmades.",
          ),
        ],
      };
    }

    if (status === "manager_approved") {
      return {
        enabled: false,
        tone: "completed",
        reasons: [
          t(
            "employee_portal.monthly.confirm_disabled_closed",
            "El mes està tancat per nòmina. No cal confirmar de nou.",
          ),
        ],
      };
    }

    if (status === "draft" && activeValidation && activeValidation.blockers.length > 0) {
      return {
        enabled: false,
        tone: "blocked",
        reasons: activeValidation.blockers.map((issue) => formatMonthlyBlocker(issue, t)),
      };
    }

    if (
      recordView === "week" &&
      activeWeek &&
      !weekAlreadyConfirmed &&
      !isPeriodEnded(activeWeek.to)
    ) {
      return {
        enabled: false,
        tone: "blocked",
        reasons: [
          t(
            "employee_portal.record.blocker_period_not_ended",
            "La setmana encara no ha acabat (només es pot confirmar després del {{period_to}})",
            { period_to: activeWeek.to },
          ),
        ],
      };
    }

    return {
      enabled: false,
      tone: "blocked",
      reasons: [
        recordView === "week"
          ? t(
              "employee_portal.record.confirm_disabled_generic",
              "Encara no pots confirmar el registre d'aquesta setmana.",
            )
          : t(
              "employee_portal.monthly.confirm_disabled_generic",
              "Encara no pots confirmar el registre d'aquest mes.",
            ),
      ],
    };
  }, [
    activeValidation,
    activeWeek,
    canConfirmL1,
    data,
    isoWeekMode,
    periodStatus?.month_fully_confirmed,
    recordView,
    requireDigitalSignature,
    signatureIsEmployeeApproval,
    showSignL2,
    status,
    t,
    weekAlreadyConfirmed,
  ]);

  async function handleConfirm() {
    if (!canConfirmL1 || !ackReviewed) return;
    setConfirming(true);
    try {
      if (recordView === "week" && activeWeek) {
        await confirmPortalPeriodReport({
          period_from: activeWeek.from,
          period_to: activeWeek.to,
          calendar_year: year,
          calendar_month: month,
        });
      } else {
        await confirmPortalMonthlyReport(year, month);
      }
      setConfirmOpen(false);
      setAckReviewed(false);
      setConfirmSuccess(true);
      await load();
    } catch (err) {
      const msg =
        err instanceof PortalApiError
          ? err.code === "month_not_confirmable" || err.code === "period_not_confirmable"
            ? t("employee_portal.monthly.confirm_not_allowed", "No es pot confirmar el registre encara")
            : err.code
          : t("employee_portal.monthly.confirm_error", "No s'ha pogut confirmar");
      setError(msg);
      setConfirmOpen(false);
    } finally {
      setConfirming(false);
    }
  }

  function prevMonth() {
    const next = navigateYearMonth(year, month, -1);
    setYear(next.year);
    setMonth(next.month);
  }

  function nextMonth() {
    const next = navigateYearMonth(year, month, 1);
    setYear(next.year);
    setMonth(next.month);
  }

  function renderBanner() {
    if (!data) return null;

    if (status === "signed" || status === "archived") {
      return (
        <div className="flex items-start gap-2 rounded-lg border border-violet-200 bg-violet-50/80 px-3 py-2.5 text-sm text-violet-900 dark:border-violet-900 dark:bg-violet-950/30 dark:text-violet-100">
          <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" />
          <p>{t("employee_portal.monthly.banner_signed", "Registre mensual signat.")}</p>
        </div>
      );
    }

    if (showSignL2) {
      return (
        <div className="space-y-2 rounded-lg border border-indigo-200 bg-indigo-50/80 px-3 py-3 text-sm text-indigo-900 dark:border-indigo-900 dark:bg-indigo-950/30 dark:text-indigo-100">
          <p className="flex items-start gap-2">
            <PenLine className="mt-0.5 h-4 w-4 shrink-0" />
            {t(
              "employee_portal.monthly.l2_pending",
              "Tens una signatura digital pendent. Això és un procés legal distint de confirmar el registre mensual.",
            )}
          </p>
          <a
            href={data.employee_sign_url!}
            target="_blank"
            rel="noopener noreferrer"
            className="bg-primary text-primary-foreground inline-flex items-center gap-2 rounded-lg px-4 py-2 text-sm font-medium"
          >
            <PenLine className="h-4 w-4" />
            {t("employee_portal.monthly.sign_document", "Signar document")}
            <ExternalLink className="h-3.5 w-3.5" />
          </a>
        </div>
      );
    }

    return null;
  }

  const visibleDays = useMemo(() => {
    if (recordView === "week" && activeWeek) {
      const weekDays = buildWeekDisplayDays(
        activeWeek,
        calendarDays,
        createEmptyCalendarDay,
      );
      if (showAllDays) return weekDays;
      return weekDays.filter(isMonthlyDayVisible);
    }
    if (showAllDays) return calendarDays;
    return calendarDays.filter(isMonthlyDayVisible);
  }, [activeWeek, calendarDays, recordView, showAllDays]);

  const displaySummary = useMemo(() => {
    if (!summary) return null;
    if (recordView === "week" && activeWeek) {
      return summarizeCalendarDays(
        filterDaysInRange(calendarDays, activeWeek.from, activeWeek.to),
        Boolean(summary.has_effective_time),
      );
    }
    return summary;
  }, [activeWeek, calendarDays, recordView, summary]);

  const showEffectiveSummary = Boolean(displaySummary?.has_effective_time);

  function renderDayCard(day: PortalMonthlyCalendarDay) {
    const muted =
      !showAllDays && !isMonthlyDayVisible(day);
    const typeLabel = monthlyDayTypeLabel(day, t);
    const hasPunch = day.starts_at || day.ends_at;
    const worked = day.worked_minutes > 0 ? day.worked_minutes : day.net_minutes;
    const balance = day.balance_minutes;
    const balanceClass =
      balance > 0
        ? "text-amber-700 dark:text-amber-300"
        : balance < 0
          ? "text-sky-700 dark:text-sky-300"
          : "text-muted-foreground";

    return (
      <li
        key={day.work_date}
        className={`rounded-lg border px-3 py-2.5 text-sm ${muted ? "opacity-55" : ""}`}
      >
        <div className="flex items-start justify-between gap-2">
          <div className="min-w-0">
            <p className="font-medium">
              {new Date(`${day.work_date}T12:00:00`).toLocaleDateString(dateLocale, {
                weekday: "short",
                day: "numeric",
                month: "short",
              })}
            </p>
            <p className="text-muted-foreground mt-0.5 text-xs">{typeLabel}</p>
            {hasPunch && (
              <p className="text-muted-foreground mt-1 tabular-nums text-xs">
                {formatTime(day.starts_at, dateLocale)} – {formatTime(day.ends_at, dateLocale)}
              </p>
            )}
          </div>
          <div className="shrink-0 text-right text-xs tabular-nums">
            {day.is_laborable || day.absence_id ? (
              <p>
                <span className="text-muted-foreground">
                  {t("employee_portal.monthly.col_expected_short", "Prev.")}{" "}
                </span>
                {formatHoursMinutes(day.expected_minutes)}
              </p>
            ) : null}
            {worked != null && worked > 0 && (
              <p className="font-medium">
                <span className="text-muted-foreground font-normal">
                  {t("employee_portal.monthly.col_worked_short", "Real")}{" "}
                </span>
                {formatHoursMinutes(worked)}
              </p>
            )}
            {day.overtime_minutes > 0 && (
              <p className="text-amber-700 dark:text-amber-300">
                {t("employee_portal.monthly.col_overtime_short", "Extra")}{" "}
                {formatHoursMinutes(day.overtime_minutes)}
              </p>
            )}
            {showEffectiveSummary && day.effective_minutes != null && day.effective_minutes > 0 && (
              <p>
                <span className="text-muted-foreground">
                  {t("employee_portal.monthly.col_effective_short", "Efectiu")}{" "}
                </span>
                {formatHoursMinutes(day.effective_minutes)}
              </p>
            )}
            {showEffectiveSummary && day.paid_minutes != null && day.paid_minutes > 0 && (
              <p>
                <span className="text-muted-foreground">
                  {t("employee_portal.monthly.col_paid_short", "Remunerable")}{" "}
                </span>
                {formatHoursMinutes(day.paid_minutes)}
              </p>
            )}
            {(day.is_laborable || worked) && balance !== 0 && (
              <p className={balanceClass}>
                {t("employee_portal.monthly.col_balance_short", "Δ")}{" "}
                {formatBalanceMinutes(balance)}
              </p>
            )}
          </div>
        </div>
      </li>
    );
  }

  return (
    <div className="flex w-full flex-col gap-5">
      <div>
        <h1 className="text-xl font-semibold">
          {t("employee_portal.record.title", "Registre")}
        </h1>
        <p className="text-muted-foreground mt-1 text-sm">
          {t(
            "employee_portal.record.legal_hint",
            "Revisa les hores previstes de l'horari laboral i les hores reals registrades abans de confirmar.",
          )}
        </p>
      </div>

      {isoWeekMode && (
        <PortalViewToggle
          value={recordView}
          onChange={setRecordView}
          ariaLabel={t("employee_portal.record.view_mode_aria", "Vista del registre")}
          options={[
            {
              value: "month",
              label: t("employee_portal.record.view_month", "Mes"),
            },
            {
              value: "week",
              label: t("employee_portal.record.view_week", "Setmana"),
            },
          ]}
        />
      )}

      <div className="flex items-center justify-center gap-1">
        {recordView === "month" ? (
          <>
            <button
              type="button"
              onClick={prevMonth}
              className="rounded-lg border p-2 hover:bg-muted"
              aria-label={t("employee_portal.monthly.prev_month", "Mes anterior")}
            >
              <ChevronLeft className="h-5 w-5" />
            </button>
            <h2 className="min-w-[10rem] text-center text-lg font-semibold capitalize">
              {monthLabel(year, month, dateLocale)}
            </h2>
            <button
              type="button"
              onClick={nextMonth}
              className="rounded-lg border p-2 hover:bg-muted"
              aria-label={t("employee_portal.monthly.next_month", "Mes següent")}
            >
              <ChevronRight className="h-5 w-5" />
            </button>
          </>
        ) : (
          <>
            <button
              type="button"
              onClick={() => setWeekIndex((i) => Math.max(0, i - 1))}
              disabled={weekIndex <= 0}
              className="rounded-lg border p-2 hover:bg-muted disabled:opacity-40"
              aria-label={t("employee_portal.record.prev_week", "Setmana anterior")}
            >
              <ChevronLeft className="h-5 w-5" />
            </button>
            <h2 className="min-w-[12rem] text-center text-lg font-semibold">
              {activeWeek
                ? weekRangeLabel(activeWeek.from, activeWeek.to, dateLocale)
                : monthLabel(year, month, dateLocale)}
            </h2>
            <button
              type="button"
              onClick={() => setWeekIndex((i) => Math.min(monthWeeks.length - 1, i + 1))}
              disabled={weekIndex >= monthWeeks.length - 1}
              className="rounded-lg border p-2 hover:bg-muted disabled:opacity-40"
              aria-label={t("employee_portal.record.next_week", "Setmana següent")}
            >
              <ChevronRight className="h-5 w-5" />
            </button>
          </>
        )}
      </div>

      {isoWeekMode && periodStatus && recordView === "month" && periodStatus.weeks_required > 0 && (
        <p className="text-muted-foreground text-center text-sm">
          {t("employee_portal.record.weeks_progress", "{{confirmed}}/{{required}} setmanes confirmades", {
            confirmed: periodStatus.weeks_confirmed,
            required: periodStatus.weeks_required,
          })}
        </p>
      )}

      {loading && (
        <div className="text-muted-foreground flex items-center justify-center gap-2 py-8 text-sm">
          <Loader2 className="h-4 w-4 animate-spin" />
          {t("employee_portal.monthly.loading", "Carregant registre…")}
        </div>
      )}

      {error && !loading && (
        <p className="text-destructive text-center text-sm" role="alert">
          {error}
        </p>
      )}

      {!loading && data && (
        <>
          <div className="flex justify-end">
            <span
              className={`rounded-full px-3 py-1 text-sm font-medium ${
                MONTHLY_STATUS_CLASS[status] ?? MONTHLY_STATUS_CLASS.draft
              }`}
            >
              {t(statusLabelKey(status), STATUS_FALLBACKS[status] ?? status)}
            </span>
          </div>

          {confirmSuccess && (
            <div className="rounded-lg border border-emerald-200 bg-emerald-50/80 px-3 py-2 text-sm text-emerald-900">
              {t("employee_portal.monthly.confirm_success", "Registre confirmat correctament.")}
            </div>
          )}

          {renderBanner()}

          {displaySummary && (
            <div className="space-y-2">
              <div className="grid grid-cols-2 gap-2 rounded-lg border bg-muted/20 p-3 text-sm sm:grid-cols-3">
                <div>
                  <p className="text-muted-foreground text-xs">
                    {t("employee_portal.monthly.worked_days", "Dies treballats")}
                  </p>
                  <p className="font-semibold tabular-nums">{displaySummary.worked_days}</p>
                </div>
                <div>
                  <p className="text-muted-foreground text-xs">
                    {t("employee_portal.monthly.expected", "Hores previstes")}
                  </p>
                  <p className="font-semibold tabular-nums">
                    {formatHoursMinutes(displaySummary.expected_minutes)}
                  </p>
                </div>
                <div>
                  <p className="text-muted-foreground text-xs">
                    {t("employee_portal.monthly.worked", "Hores treballades")}
                  </p>
                  <p className="font-semibold tabular-nums">
                    {formatHoursMinutes(displaySummary.worked_minutes)}
                  </p>
                </div>
                <div>
                  <p className="text-muted-foreground text-xs">
                    {t("employee_portal.monthly.difference", "Diferència")}
                  </p>
                  <p className="font-semibold tabular-nums">
                    {formatBalanceMinutes(displaySummary.difference_minutes)}
                  </p>
                </div>
                {displaySummary.overtime_minutes > 0 && (
                  <div>
                    <p className="text-muted-foreground text-xs">
                      {t("employee_portal.monthly.overtime_total", "Hores extra")}
                    </p>
                    <p className="font-semibold tabular-nums text-amber-700 dark:text-amber-300">
                      {formatHoursMinutes(displaySummary.overtime_minutes)}
                    </p>
                  </div>
                )}
                {showEffectiveSummary && (displaySummary.effective_minutes ?? 0) > 0 && (
                  <div>
                    <p className="text-muted-foreground text-xs">
                      {t("employee_portal.monthly.effective_total", "Temps efectiu")}
                    </p>
                    <p className="font-semibold tabular-nums">
                      {formatHoursMinutes(displaySummary.effective_minutes ?? 0)}
                    </p>
                  </div>
                )}
                {showEffectiveSummary && (displaySummary.paid_minutes ?? 0) > 0 && (
                  <div>
                    <p className="text-muted-foreground text-xs">
                      {t("employee_portal.monthly.paid_total", "Temps remunerable")}
                    </p>
                    <p className="font-semibold tabular-nums">
                      {formatHoursMinutes(displaySummary.paid_minutes ?? 0)}
                    </p>
                  </div>
                )}
                {showEffectiveSummary && (displaySummary.travel_minutes ?? 0) > 0 && (
                  <div>
                    <p className="text-muted-foreground text-xs">
                      {t("employee_portal.monthly.travel_total", "Desplaçament")}
                    </p>
                    <p className="font-semibold tabular-nums">
                      {formatHoursMinutes(displaySummary.travel_minutes ?? 0)}
                    </p>
                  </div>
                )}
                {displaySummary.absence_days > 0 && (
                  <div>
                    <p className="text-muted-foreground text-xs">
                      {t("employee_portal.monthly.absence_days", "Dies absència")}
                    </p>
                    <p className="font-semibold tabular-nums">{displaySummary.absence_days}</p>
                  </div>
                )}
              </div>
              <p className="text-muted-foreground text-xs">
                {t(
                  "employee_portal.monthly.l1_disclaimer",
                  "En confirmar, declares que els dies i les hores del registre són correctes. Això no és una signatura electrònica.",
                )}
              </p>
            </div>
          )}

          {confirmButtonState && (
            <div className="space-y-2 rounded-lg border bg-muted/15 p-4">
              <p className="text-sm font-medium">
                {t(
                  "employee_portal.monthly.confirm_section_title",
                  "Confirmació del registre",
                )}
              </p>
              {confirmButtonState.tone === "ready" ? (
                <p className="text-muted-foreground text-sm">
                  {employeeConfirmRequired
                    ? recordView === "week"
                      ? t(
                          "employee_portal.record.confirm_section_ready_week",
                          "Si els dies i les hores d'aquesta setmana són correctes, confirma el registre.",
                        )
                      : t(
                          "employee_portal.monthly.confirm_section_ready_required",
                          "Si els dies i les hores són correctes, confirma el registre del mes.",
                        )
                    : t(
                        "employee_portal.monthly.confirm_section_ready_optional",
                        "Pots confirmar el registre per facilitar la revisió de nòmina.",
                      )}
                </p>
              ) : confirmButtonState.tone === "completed" ? (
                <p className="flex items-start gap-2 text-sm text-emerald-900 dark:text-emerald-100">
                  <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
                  <span>{confirmButtonState.reasons[0]}</span>
                </p>
              ) : confirmButtonState.tone === "info" ? (
                <p className="text-muted-foreground text-sm">{confirmButtonState.reasons[0]}</p>
              ) : (
                <div className="text-muted-foreground space-y-1 text-sm">
                  {confirmButtonState.reasons.length > 1 ? (
                    <p>
                      {t(
                        recordView === "week"
                          ? "employee_portal.record.confirm_blocked_intro"
                          : "employee_portal.monthly.confirm_blocked_intro",
                        recordView === "week"
                          ? "Encara no pots confirmar aquesta setmana:"
                          : "Encara no pots confirmar:",
                      )}
                    </p>
                  ) : null}
                  {confirmButtonState.reasons.length === 1 ? (
                    <p>{confirmButtonState.reasons[0]}</p>
                  ) : (
                    <ul className="list-disc space-y-0.5 pl-5">
                      {confirmButtonState.reasons.map((reason, i) => (
                        <li key={i}>{reason}</li>
                      ))}
                    </ul>
                  )}
                </div>
              )}
              {confirmButtonState.enabled ? (
                <button
                  type="button"
                  onClick={() => setConfirmOpen(true)}
                  className="bg-primary text-primary-foreground hover:opacity-95 w-full rounded-lg px-4 py-3 text-sm font-medium transition"
                >
                  {t(
                    recordView === "week"
                      ? "employee_portal.record.confirm_button_week"
                      : "employee_portal.monthly.confirm_button",
                    recordView === "week"
                      ? "Confirmar aquesta setmana"
                      : "Confirmar el meu registre",
                  )}
                </button>
              ) : confirmButtonState.tone === "blocked" ? (
                <button
                  type="button"
                  disabled
                  className="bg-primary text-primary-foreground w-full cursor-not-allowed rounded-lg px-4 py-3 text-sm font-medium opacity-50"
                  title={confirmButtonState.reasons.join(" ")}
                >
                  {t(
                    recordView === "week"
                      ? "employee_portal.record.confirm_button_week"
                      : "employee_portal.monthly.confirm_button",
                    recordView === "week"
                      ? "Confirmar aquesta setmana"
                      : "Confirmar el meu registre",
                  )}
                </button>
              ) : null}
            </div>
          )}

          {((recordView === "week" && activeWeek) || calendarDays.length > 0) && (
            <div className="space-y-3">
              <div className="space-y-2">
            <h3 className="text-base font-semibold">
              {t(
                recordView === "week"
                  ? "employee_portal.record.days_title_week"
                  : "employee_portal.monthly.days_title",
                recordView === "week" ? "Detall de la setmana" : "Detall per dia",
              )}
            </h3>
                <p className="text-muted-foreground text-sm">
                  {t(
                    recordView === "week"
                      ? "employee_portal.record.view_filter_hint"
                      : "employee_portal.monthly.view_filter_hint",
                    recordView === "week"
                      ? "Filtra quins dies de la setmana vols veure al detall."
                      : "Filtra quins dies del mes vols veure al detall.",
                  )}
                </p>
                <PortalViewToggle
                  value={showAllDays ? "all" : "relevant"}
                  onChange={(v) => setShowAllDays(v === "all")}
                  ariaLabel={t(
                    recordView === "week"
                      ? "employee_portal.record.view_filter_aria"
                      : "employee_portal.monthly.view_filter_aria",
                    recordView === "week"
                      ? "Vista del detall setmanal"
                      : "Vista del calendari mensual",
                  )}
                  options={[
                    {
                      value: "relevant",
                      label: t(
                        "employee_portal.monthly.show_relevant",
                        "Només dies rellevants",
                      ),
                    },
                    {
                      value: "all",
                      label: t(
                        recordView === "week"
                          ? "employee_portal.record.show_all_week"
                          : "employee_portal.monthly.show_all",
                        recordView === "week" ? "Tota la setmana" : "Tot el mes",
                      ),
                    },
                  ]}
                />
              </div>
              <ul className="space-y-2">{visibleDays.map(renderDayCard)}</ul>
              {visibleDays.length === 0 && (
                <p className="text-muted-foreground py-4 text-center text-sm">
                  {t(
                    recordView === "week"
                      ? "employee_portal.record.no_relevant_days"
                      : "employee_portal.monthly.no_relevant_days",
                    recordView === "week"
                      ? "Cap dia laborable o amb activitat en aquesta setmana"
                      : "Cap dia laborable o amb activitat en aquest mes",
                  )}
                </p>
              )}
            </div>
          )}

          {calendarDays.length === 0 && recordView !== "week" && (
            <p className="text-muted-foreground py-6 text-center text-sm">
              {t("employee_portal.monthly.empty", "Cap dia registrat en aquest mes")}
            </p>
          )}
        </>
      )}

      {confirmOpen && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-4 sm:items-center">
          <div
            className="bg-background w-full max-w-md rounded-xl border p-5 shadow-lg"
            role="dialog"
            aria-modal="true"
          >
            <h3 className="text-base font-semibold">
              {t(
                recordView === "week"
                  ? "employee_portal.record.confirm_modal_title_week"
                  : "employee_portal.monthly.confirm_modal_title",
                recordView === "week"
                  ? "Confirmar el registre d'aquesta setmana"
                  : "Confirmar el meu registre mensual",
              )}
            </h3>
            <p className="text-muted-foreground mt-1 text-sm">
              {recordView === "week" && activeWeek
                ? t(
                    "employee_portal.record.confirm_modal_desc_week",
                    "Revisa els dies i les hores de {{range}} abans de confirmar. Aquesta acció no és una signatura electrònica.",
                    { range: weekRangeLabel(activeWeek.from, activeWeek.to, dateLocale) },
                  )
                : t(
                    "employee_portal.monthly.confirm_modal_desc",
                    "Revisa els dies i les hores de {{month}} abans de confirmar. Aquesta acció no és una signatura electrònica.",
                    { month: monthLabel(year, month, dateLocale) },
                  )}
            </p>

            <label className="mt-4 flex items-start gap-2 text-sm">
              <input
                type="checkbox"
                className="mt-1"
                checked={ackReviewed}
                onChange={(e) => setAckReviewed(e.target.checked)}
              />
              <span>
                {showEffectiveSummary
                  ? t(
                      "employee_portal.monthly.confirm_ack_effective",
                      "He revisat el temps remunerable, el temps efectiu i les hores extra del mes; confirmo que el registre és correcte.",
                    )
                  : t(
                      "employee_portal.monthly.confirm_ack",
                      "He revisat les hores previstes de l'horari i les hores reals del mes; confirmo que el registre és correcte.",
                    )}
              </span>
            </label>

            <div className="mt-5 flex gap-2">
              <button
                type="button"
                className="flex-1 rounded-lg border px-4 py-2 text-sm"
                onClick={() => {
                  setConfirmOpen(false);
                  setAckReviewed(false);
                }}
              >
                {t("employee_portal.monthly.cancel", "Cancel·lar")}
              </button>
              <button
                type="button"
                disabled={!ackReviewed || confirming}
                className="bg-primary text-primary-foreground flex-1 rounded-lg px-4 py-2 text-sm font-medium disabled:opacity-50"
                onClick={() => void handleConfirm()}
              >
                {confirming ? (
                  <Loader2 className="mx-auto h-4 w-4 animate-spin" />
                ) : (
                  t("employee_portal.monthly.confirm_submit", "Confirmar")
                )}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

/** @deprecated Use PortalRecordPage — kept for route imports */
export const PortalMonthlyPage = PortalRecordPage;
