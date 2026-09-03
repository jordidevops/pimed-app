"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { useTranslation } from "react-i18next";
import { ChevronLeft, ChevronRight, Loader2 } from "lucide-react";
import {
  fetchPortalSchedule,
  PortalApiError,
  type PortalScheduleAbsence,
  type PortalScheduleDay,
} from "../api/portalApi";
import { PortalPushOptIn } from "./PortalPushOptIn";
import {
  addDaysIso,
  formatIntervalsCompact,
  formatIntervalsList,
  formatWeekPeriodLabel,
  monthRange,
  parseWorkIntervals,
  startOfWeekIso,
  weekRange,
} from "../utils/scheduleUtils";
import { getPortalCalendarAnchor, getPortalTodayIso } from "../utils/portalDateUtils";
import {
  ABSENCE_RING,
  buildMonthGrid,
  findAbsenceForDate,
  resolveScheduleDayKind,
  SCHEDULE_DAY_STYLE,
  type ScheduleDayKind,
} from "../utils/scheduleDayStyle";

type ScheduleView = "month" | "week";

const SCHEDULE_KIND_FALLBACKS: Record<ScheduleDayKind, string> = {
  work: "Laboral",
  holiday: "Festiu",
  vacation: "Vacances",
  non_working: "No laborable",
  unknown: "Sense dades",
};

const FALLBACK_MONTHS = [
  "Gener", "Febrer", "Març", "Abril", "Maig", "Juny",
  "Juliol", "Agost", "Setembre", "Octubre", "Novembre", "Desembre",
];

const FALLBACK_DOW = ["Dl", "Dt", "Dc", "Dj", "Dv", "Ds", "Dg"];

function dayCellClasses(opts: {
  styleCell: string;
  absenceRing: string;
  isSelected: boolean;
  isToday: boolean;
  compact?: boolean;
}): string {
  const { styleCell, absenceRing, isSelected, isToday, compact } = opts;
  return [
    "relative transition",
    compact ? "rounded-md p-0.5 text-xs font-medium" : "rounded-lg p-3 text-sm",
    styleCell,
    absenceRing,
    isToday ? "outline outline-2 outline-offset-[-2px] outline-sky-500 z-[1] font-bold" : "",
    isSelected ? "ring-2 ring-foreground/75 ring-offset-1 shadow-sm z-[2]" : "",
  ]
    .filter(Boolean)
    .join(" ");
}

function monthCellScheduleHint(
  day: PortalScheduleDay | undefined,
  kind: ScheduleDayKind,
  overnightSuffix: string,
): string | null {
  if (!day || (kind !== "work" && kind !== "holiday")) return null;
  const intervals = parseWorkIntervals(day.work_intervals);
  if (intervals.length > 0) {
    return formatIntervalsCompact(intervals, overnightSuffix);
  }
  return null;
}

export function PortalSchedulePage() {
  const { t, i18n } = useTranslation("portal");
  const router = useRouter();
  const todayIso = getPortalTodayIso();

  const [view, setView] = useState<ScheduleView>("month");
  const [year, setYear] = useState(() => getPortalCalendarAnchor().year);
  const [month, setMonth] = useState(() => getPortalCalendarAnchor().month);
  const [weekStart, setWeekStart] = useState(() => startOfWeekIso(getPortalCalendarAnchor().todayIso));
  const [selectedDate, setSelectedDate] = useState<string | null>(() => getPortalCalendarAnchor().todayIso);
  const [days, setDays] = useState<PortalScheduleDay[]>([]);
  const [absences, setAbsences] = useState<PortalScheduleAbsence[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const monthNames = useMemo(() => {
    const raw = t("employee_portal.schedule.months", { returnObjects: true, defaultValue: FALLBACK_MONTHS });
    return Array.isArray(raw) ? (raw as string[]) : FALLBACK_MONTHS;
  }, [t, i18n.language]);

  const dowAbbr = useMemo(() => {
    const raw = t("employee_portal.schedule.dow_abbr", { returnObjects: true, defaultValue: FALLBACK_DOW });
    return Array.isArray(raw) ? (raw as string[]) : FALLBACK_DOW;
  }, [t, i18n.language]);

  const { from, to } = useMemo(() => {
    if (view === "week") {
      const wr = weekRange(weekStart);
      return { from: wr.from, to: wr.to };
    }
    return monthRange(year, month);
  }, [view, weekStart, year, month]);

  const weekDates = useMemo(
    () => (view === "week" ? weekRange(weekStart).dates : []),
    [view, weekStart],
  );

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await fetchPortalSchedule(from, to);
      setDays(data.days ?? []);
      setAbsences(data.absences ?? []);
    } catch (err) {
      if (err instanceof PortalApiError && ["missing_session", "session_expired", "token_revoked"].includes(err.code)) {
        router.replace("/portal/expired");
        return;
      }
      setError(
        err instanceof PortalApiError && err.code === "load_failed"
          ? t("employee_portal.schedule.error_load_failed", "No s'ha pogut carregar l'horari")
          : err instanceof PortalApiError
            ? err.code
            : t("employee_portal.schedule.error_load_failed", "No s'ha pogut carregar l'horari"),
      );
    } finally {
      setLoading(false);
    }
  }, [from, to, router, t]);

  useEffect(() => {
    void load();
  }, [load]);

  const dayMap = useMemo(() => new Map(days.map((d) => [d.date, d])), [days]);
  const grid = useMemo(() => buildMonthGrid(year, month), [year, month]);
  const selectedDay = selectedDate ? dayMap.get(selectedDate) : undefined;
  const selectedAbsence = selectedDate ? findAbsenceForDate(selectedDate, absences) : undefined;

  const dateLocale = i18n.language === "en" ? "en-GB" : i18n.language === "es" ? "es-ES" : "ca-ES";

  const periodLabel =
    view === "month"
      ? `${monthNames[month] ?? FALLBACK_MONTHS[month]} ${year}`
      : formatWeekPeriodLabel(weekStart, dateLocale, monthNames);

  function scheduleTypeLabel(kind: ScheduleDayKind): string {
    const key = `employee_portal.${SCHEDULE_DAY_STYLE[kind].labelKey}`;
    return t(key, SCHEDULE_KIND_FALLBACKS[kind]);
  }

  function dayLabel(day: PortalScheduleDay | undefined): string {
    if (!day) return t("employee_portal.schedule.type_unknown", "Sense dades");
    if (day.is_absence && day.absence_type) {
      return t(`employee_portal.schedule.absence_${day.absence_type}`, day.absence_type);
    }
    const kind = resolveScheduleDayKind(day);
    if (kind === "holiday" && day.holiday_name) return day.holiday_name;
    return scheduleTypeLabel(kind);
  }

  function formatDuration(minutes: number): string {
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    if (h === 0) {
      return t("employee_portal.schedule.duration_minutes", "{{count}} min", { count: m });
    }
    if (m === 0) {
      return t("employee_portal.schedule.duration_hours", "{{count}} h", { count: h });
    }
    return t("employee_portal.schedule.duration_hours_minutes", "{{hours}} h {{minutes}} min", {
      hours: h,
      minutes: m,
    });
  }

  function dayDetail(day: PortalScheduleDay | undefined): string {
    if (!day) return "—";
    const intervals = parseWorkIntervals(day.work_intervals);
    if (intervals.length > 0) {
      return formatIntervalsList(intervals, t("employee_portal.schedule.overnight_suffix", " (+1)"));
    }
    if (day.expected_minutes > 0) {
      return formatDuration(day.expected_minutes);
    }
    return dayLabel(day);
  }

  function syncMonthFromIso(iso: string) {
    const d = new Date(`${iso}T12:00:00`);
    setYear(d.getFullYear());
    setMonth(d.getMonth());
  }

  function goToToday() {
    const anchor = getPortalCalendarAnchor();
    syncMonthFromIso(anchor.todayIso);
    setWeekStart(startOfWeekIso(anchor.todayIso));
    setSelectedDate(anchor.todayIso);
  }

  function prevPeriod() {
    if (view === "week") {
      const next = addDaysIso(weekStart, -7);
      setWeekStart(next);
      syncMonthFromIso(next);
    } else if (month === 0) {
      setYear((y) => y - 1);
      setMonth(11);
    } else {
      setMonth((m) => m - 1);
    }
  }

  function nextPeriod() {
    if (view === "week") {
      const next = addDaysIso(weekStart, 7);
      setWeekStart(next);
      syncMonthFromIso(next);
    } else if (month === 11) {
      setYear((y) => y + 1);
      setMonth(0);
    } else {
      setMonth((m) => m + 1);
    }
  }

  function switchView(next: ScheduleView) {
    setView(next);
    if (next === "week") {
      const anchor = selectedDate ?? todayIso;
      setWeekStart(startOfWeekIso(anchor));
    }
  }

  function renderDayDetailPanel() {
    if (!selectedDate) return null;
    return (
      <div className="rounded-lg border bg-card p-4 text-sm">
        <p className="text-muted-foreground text-xs">
          {new Date(`${selectedDate}T12:00:00`).toLocaleDateString(dateLocale, {
            weekday: "long",
            day: "numeric",
            month: "long",
            year: "numeric",
          })}
        </p>
        <p className="mt-2 font-medium">{dayLabel(selectedDay)}</p>
        <p className="text-muted-foreground mt-1">{dayDetail(selectedDay)}</p>
        {selectedAbsence && (
          <p className="mt-2 text-violet-700 dark:text-violet-300">
            {t("employee_portal.schedule.absence_status", "Absència")}:{" "}
            {t(`employee_portal.schedule.status_${selectedAbsence.status}`, selectedAbsence.status)}
          </p>
        )}
      </div>
    );
  }

  return (
    <div className="flex w-full flex-col gap-4">
      <PortalPushOptIn />
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-1">
          <button
            type="button"
            className="rounded-lg border p-2 hover:bg-muted"
            onClick={prevPeriod}
            aria-label={
              view === "week"
                ? t("employee_portal.schedule.prev_week", "Setmana anterior")
                : t("employee_portal.schedule.prev_month", "Mes anterior")
            }
          >
            <ChevronLeft className="h-5 w-5" />
          </button>
          <h1 className="min-w-[9rem] text-center text-base font-semibold">{periodLabel}</h1>
          <button
            type="button"
            className="rounded-lg border p-2 hover:bg-muted"
            onClick={nextPeriod}
            aria-label={
              view === "week"
                ? t("employee_portal.schedule.next_week", "Setmana següent")
                : t("employee_portal.schedule.next_month", "Mes següent")
            }
          >
            <ChevronRight className="h-5 w-5" />
          </button>
        </div>

        <div className="flex items-center gap-2">
          <button
            type="button"
            className="rounded-lg border px-3 py-1.5 text-xs font-medium hover:bg-muted"
            onClick={goToToday}
          >
            {t("employee_portal.schedule.today", "Avui")}
          </button>
          <div className="flex rounded-lg border p-0.5">
            {(["month", "week"] as const).map((v) => (
              <button
                key={v}
                type="button"
                className={`rounded-md px-3 py-1 text-xs font-medium transition ${
                  view === v
                    ? "bg-primary text-primary-foreground"
                    : "text-muted-foreground hover:bg-muted"
                }`}
                onClick={() => switchView(v)}
              >
                {v === "month"
                  ? t("employee_portal.schedule.view_month", "Mes")
                  : t("employee_portal.schedule.view_week", "Setmana")}
              </button>
            ))}
          </div>
        </div>
      </div>

      {loading && (
        <div className="text-muted-foreground flex items-center justify-center gap-2 py-8 text-sm">
          <Loader2 className="h-4 w-4 animate-spin" />
          {t("employee_portal.schedule.loading", "Carregant horari…")}
        </div>
      )}

      {error && !loading && (
        <p className="text-destructive text-center text-sm" role="alert">
          {error}
        </p>
      )}

      {!loading && !error && view === "month" && (
        <>
          <div className="grid grid-cols-7 gap-1 text-center text-xs font-medium text-muted-foreground">
            {dowAbbr.map((d) => (
              <div key={d} className="py-1">
                {d}
              </div>
            ))}
          </div>

          <div className="grid grid-cols-7 gap-1">
            {grid.map((date, idx) => {
              if (!date) {
                return <div key={`empty-${idx}`} className="min-h-[3.25rem]" />;
              }
              const day = dayMap.get(date);
              const kind = resolveScheduleDayKind(day);
              const style = SCHEDULE_DAY_STYLE[kind];
              const absence = findAbsenceForDate(date, absences);
              const ring = absence ? ABSENCE_RING[absence.status] ?? "" : "";
              const isSelected = selectedDate === date;
              const isToday = date === todayIso;
              const scheduleHint = monthCellScheduleHint(
                day,
                kind,
                t("employee_portal.schedule.overnight_suffix", " (+1)"),
              );

              return (
                <button
                  key={date}
                  type="button"
                  onClick={() => setSelectedDate(date)}
                  className={`min-h-[3.25rem] ${dayCellClasses({
                    styleCell: style.cell,
                    absenceRing: ring,
                    isSelected,
                    isToday,
                    compact: true,
                  })}`}
                >
                  <span className="flex h-full flex-col items-center justify-center gap-0.5 px-0.5 py-1 leading-tight">
                    <span className={isToday ? "font-bold" : "font-semibold"}>
                      {Number(date.slice(8, 10))}
                    </span>
                    {scheduleHint && (
                      <span className="max-w-full truncate text-[9px] font-normal opacity-90">
                        {scheduleHint}
                      </span>
                    )}
                  </span>
                </button>
              );
            })}
          </div>

          <Legend scheduleTypeLabel={scheduleTypeLabel} />
          {renderDayDetailPanel()}
        </>
      )}

      {!loading && !error && view === "week" && (
        <>
          <ul className="space-y-2">
            {weekDates.map((date, idx) => {
              const day = dayMap.get(date);
              const kind = resolveScheduleDayKind(day);
              const style = SCHEDULE_DAY_STYLE[kind];
              const absence = findAbsenceForDate(date, absences);
              const ring = absence ? ABSENCE_RING[absence.status] ?? "" : "";
              const isSelected = selectedDate === date;
              const isToday = date === todayIso;
              const dowLabel = dowAbbr[idx] ?? "";

              return (
                <li key={date}>
                  <button
                    type="button"
                    onClick={() => setSelectedDate(date)}
                    className={`w-full text-left ${dayCellClasses({
                      styleCell: style.cell,
                      absenceRing: ring,
                      isSelected,
                      isToday,
                    })}`}
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="shrink-0">
                        <p className="text-muted-foreground text-xs font-medium">{dowLabel}</p>
                        <p className="text-lg font-bold leading-tight">{Number(date.slice(8, 10))}</p>
                        {isToday && (
                          <span className="mt-1 inline-block rounded border border-sky-500 px-1.5 py-0.5 text-[10px] font-semibold text-sky-700 dark:text-sky-300">
                            {t("employee_portal.schedule.today", "Avui")}
                          </span>
                        )}
                      </div>
                      <div className="min-w-0 flex-1">
                        <p className="font-medium">{dayLabel(day)}</p>
                        <p className="text-muted-foreground mt-0.5 truncate text-xs">{dayDetail(day)}</p>
                      </div>
                    </div>
                  </button>
                </li>
              );
            })}
          </ul>

          <Legend scheduleTypeLabel={scheduleTypeLabel} />
          {renderDayDetailPanel()}
        </>
      )}
    </div>
  );
}

function Legend({
  scheduleTypeLabel,
}: {
  scheduleTypeLabel: (kind: ScheduleDayKind) => string;
}) {
  const { t } = useTranslation("portal");
  return (
    <div className="flex flex-wrap gap-3 text-xs">
      {(Object.keys(SCHEDULE_DAY_STYLE) as ScheduleDayKind[]).map((kind) => (
        <span key={kind} className="flex items-center gap-1.5">
          <span className={`h-3 w-3 rounded-sm ${SCHEDULE_DAY_STYLE[kind].legend}`} />
          {scheduleTypeLabel(kind)}
        </span>
      ))}
      <span className="flex items-center gap-1.5">
        <span className="h-3 w-3 rounded-sm bg-violet-100 ring-2 ring-inset ring-violet-600" />
        {t("employee_portal.schedule.legend_absence", "Absència (sol·licitud/aprovada)")}
      </span>
    </div>
  );
}
