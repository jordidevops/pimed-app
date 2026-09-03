export function previousYearMonth(): { year: number; month: number } {
  const d = new Date();
  d.setDate(1);
  d.setMonth(d.getMonth() - 1);
  return { year: d.getFullYear(), month: d.getMonth() + 1 };
}

export function parseYearMonth(searchParams: URLSearchParams): { year: number; month: number } {
  const yearRaw = searchParams.get("year");
  const monthRaw = searchParams.get("month");
  const year = yearRaw ? Number(yearRaw) : NaN;
  const month = monthRaw ? Number(monthRaw) : NaN;
  if (Number.isInteger(year) && Number.isInteger(month) && month >= 1 && month <= 12) {
    return { year, month };
  }
  return previousYearMonth();
}

export function navigateYearMonth(
  year: number,
  month: number,
  direction: 1 | -1,
): { year: number; month: number } {
  const d = new Date(year, month - 1 + direction, 1);
  return { year: d.getFullYear(), month: d.getMonth() + 1 };
}

export function monthLabel(year: number, month: number, locale: string): string {
  return new Date(year, month - 1, 1).toLocaleDateString(locale, {
    month: "long",
    year: "numeric",
  });
}

export function formatMinutes(minutes: number | null | undefined): { hours: number; mins: number } {
  const total = minutes ?? 0;
  const abs = Math.abs(total);
  return { hours: Math.floor(abs / 60), mins: abs % 60 };
}

/** Format hores sense dependre d'i18n (evita {{minutes}} literal). */
export function formatHoursMinutes(minutes: number | null | undefined): string {
  if (minutes == null) return "—";
  const sign = minutes < 0 ? "-" : "";
  const { hours, mins } = formatMinutes(minutes);
  return `${sign}${hours}h ${String(mins).padStart(2, "0")}m`;
}

export function formatBalanceMinutes(minutes: number | null | undefined): string {
  if (minutes == null || minutes === 0) return "—";
  const sign = minutes > 0 ? "+" : "";
  return `${sign}${formatHoursMinutes(minutes)}`;
}

export function formatTime(iso: string | null | undefined, locale: string): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleTimeString(locale, { hour: "2-digit", minute: "2-digit" });
}

export function isMonthlyDayVisible(day: {
  is_laborable: boolean;
  worked_minutes: number;
  absence_id: string | null;
  starts_at: string | null;
  payroll_action: string | null;
}): boolean {
  return (
    day.is_laborable ||
    day.worked_minutes > 0 ||
    !!day.absence_id ||
    !!day.starts_at ||
    day.payroll_action === "missing_punch"
  );
}

export function monthlyDayTypeLabel(
  day: {
    absence_id: string | null;
    absence_type: string | null;
    is_it: boolean;
    holiday_name: string | null;
    day_type: string | null;
    is_laborable: boolean;
    payroll_action: string | null;
  },
  t: (key: string, fallback: string) => string,
): string {
  if (day.absence_id && day.absence_type) {
    if (day.is_it) {
      return t("employee_portal.monthly.type_it", "Baixa IT");
    }
    const key = `employee_portal.schedule.absence_${day.absence_type}`;
    return t(key, day.absence_type);
  }
  if (day.holiday_name) return day.holiday_name;
  if (day.day_type === "holiday") {
    return t("employee_portal.schedule.type_holiday", "Festiu");
  }
  if (day.day_type === "vacation") {
    return t("employee_portal.schedule.type_vacation", "Vacances");
  }
  if (day.payroll_action === "missing_punch") {
    return t("employee_portal.monthly.type_missing", "Sense registre");
  }
  if (day.is_laborable) {
    return t("employee_portal.schedule.type_work", "Laboral");
  }
  return t("employee_portal.schedule.type_non_working", "No laborable");
}

export const MONTHLY_STATUS_CLASS: Record<string, string> = {
  draft: "bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-200",
  employee_confirmed: "bg-sky-100 text-sky-800 dark:bg-sky-950/40 dark:text-sky-200",
  manager_approved: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200",
  signed: "bg-violet-100 text-violet-800 dark:bg-violet-950/40 dark:text-violet-200",
  archived: "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300",
};

export function formatMonthlyBlocker(
  issue: { code: string; count?: number; work_date?: string; work_dates?: string[]; period_to?: string },
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string,
): string {
  const dates =
    issue.work_dates?.length
      ? issue.work_dates.slice(0, 3).join(", ") + (issue.work_dates.length > 3 ? "…" : "")
      : issue.work_date ?? "";

  switch (issue.code) {
    case "PERIOD_NOT_ENDED":
      return t(
        "employee_portal.monthly.blocker_period_not_ended",
        "El període encara no ha acabat (només es pot confirmar després del {{period_to}})",
        { period_to: (issue as { period_to?: string }).period_to ?? "" },
      );
    case "FUTURE_MONTH":
      return t("employee_portal.monthly.blocker_future_month", "El mes encara no ha passat");
    case "CURRENT_MONTH_INCOMPLETE":
      return t(
        "employee_portal.monthly.blocker_current_incomplete",
        "El mes encara té dies laborables pendents",
      );
    case "OPEN_TIME_ENTRY":
      return (
        t("employee_portal.monthly.blocker_open_entry", "{{count}} jornada(es) oberta(es)", {
          count: issue.count ?? 0,
        }) + (dates ? ` (${dates})` : "")
      );
    case "NEEDS_REVIEW":
      return (
        t("employee_portal.monthly.blocker_needs_review", "{{count}} dia(es) amb revisió pendent", {
          count: issue.count ?? 0,
        }) + (dates ? ` (${dates})` : "")
      );
    case "MISSING_WORKDAY_RECORD":
      return (
        t(
          "employee_portal.monthly.blocker_missing_workday",
          "{{count}} dia(es) laborable(s) sense registre ni absència",
          { count: issue.count ?? 0 },
        ) + (dates ? ` (${dates})` : "")
      );
    case "EMPLOYEE_CONFIRM_VIA_SIGNATURE":
      return t(
        "employee_portal.monthly.blocker_confirm_via_signature",
        "La confirmació es fa signant el registre després del tancament per nòmina.",
      );
    default:
      return issue.code;
  }
}

export type RecordViewMode = "month" | "week";

export interface IsoWeekPeriod {
  from: string;
  to: string;
}

function pad2(n: number): string {
  return String(n).padStart(2, "0");
}

export function toIsoDate(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

export function isoWeekStart(isoDate: string): string {
  const d = new Date(`${isoDate}T12:00:00`);
  const dow = d.getDay();
  const diff = (dow + 6) % 7;
  d.setDate(d.getDate() - diff);
  return toIsoDate(d);
}

export function isoWeekEnd(isoDate: string): string {
  const start = new Date(`${isoWeekStart(isoDate)}T12:00:00`);
  start.setDate(start.getDate() + 6);
  return toIsoDate(start);
}

export function listIsoWeeksInMonth(year: number, month: number): IsoWeekPeriod[] {
  const monthStart = new Date(year, month - 1, 1);
  const monthEnd = new Date(year, month, 0);
  const weekStarts = new Set<string>();

  for (let d = new Date(monthStart); d <= monthEnd; d.setDate(d.getDate() + 1)) {
    weekStarts.add(isoWeekStart(toIsoDate(d)));
  }

  return [...weekStarts].sort().map((from) => ({
    from,
    to: isoWeekEnd(from),
  }));
}

export function defaultWeekIndexForMonth(
  weeks: IsoWeekPeriod[],
  year: number,
  month: number,
): number {
  if (!weeks.length) return 0;
  const today = toIsoDate(new Date());
  const inMonth = weeks.findIndex((w) => today >= w.from && today <= w.to);
  if (inMonth >= 0) return inMonth;
  let prev = -1;
  for (let i = weeks.length - 1; i >= 0; i -= 1) {
    if (weeks[i].to < today) {
      prev = i;
      break;
    }
  }
  if (prev >= 0) return prev;
  return weeks.length - 1;
}

export function weekRangeLabel(from: string, to: string, locale: string): string {
  const start = new Date(`${from}T12:00:00`);
  const end = new Date(`${to}T12:00:00`);
  const sameMonth = start.getMonth() === end.getMonth() && start.getFullYear() === end.getFullYear();
  if (sameMonth) {
    return `${start.toLocaleDateString(locale, { day: "numeric" })} – ${end.toLocaleDateString(locale, {
      day: "numeric",
      month: "long",
      year: "numeric",
    })}`;
  }
  return `${start.toLocaleDateString(locale, {
    day: "numeric",
    month: "short",
  })} – ${end.toLocaleDateString(locale, {
    day: "numeric",
    month: "short",
    year: "numeric",
  })}`;
}

export function filterDaysInRange<T extends { work_date: string }>(
  days: T[],
  from: string,
  to: string,
): T[] {
  return days.filter((d) => d.work_date >= from && d.work_date <= to);
}

export function enumerateIsoDates(from: string, to: string): string[] {
  const dates: string[] = [];
  const cur = new Date(`${from}T12:00:00`);
  const end = new Date(`${to}T12:00:00`);
  while (cur <= end) {
    dates.push(toIsoDate(cur));
    cur.setDate(cur.getDate() + 1);
  }
  return dates;
}

export function monthDateBounds(year: number, month: number): { from: string; to: string } {
  return {
    from: toIsoDate(new Date(year, month - 1, 1)),
    to: toIsoDate(new Date(year, month, 0)),
  };
}

/** Omple dilluns–diumenge amb placeholders per als dies sense dades (p. ex. fora del mes carregat). */
export function buildWeekDisplayDays<T extends { work_date: string }>(
  week: IsoWeekPeriod,
  calendarDays: T[],
  createEmpty: (workDate: string) => T,
): T[] {
  const byDate = new Map(calendarDays.map((d) => [d.work_date, d]));
  return enumerateIsoDates(week.from, week.to).map(
    (date) => byDate.get(date) ?? createEmpty(date),
  );
}

export function summarizeCalendarDays(
  days: Array<{
    expected_minutes: number;
    worked_minutes: number;
    overtime_minutes: number;
    balance_minutes: number;
    is_laborable: boolean;
    absence_id: string | null;
    effective_minutes?: number | null;
    paid_minutes?: number | null;
    travel_minutes?: number | null;
  }>,
  hasEffectiveTime: boolean,
) {
  let workedMinutes = 0;
  let expectedMinutes = 0;
  let overtimeMinutes = 0;
  let workedDays = 0;
  let laborableDays = 0;
  let absenceDays = 0;
  let effectiveMinutes = 0;
  let paidMinutes = 0;
  let travelMinutes = 0;

  for (const day of days) {
    const worked =
      day.worked_minutes > 0 ? day.worked_minutes : 0;
    workedMinutes += worked;
    expectedMinutes += day.expected_minutes ?? 0;
    overtimeMinutes += day.overtime_minutes ?? 0;
    if (worked > 0) workedDays += 1;
    if (day.is_laborable) laborableDays += 1;
    if (day.absence_id) absenceDays += 1;
    effectiveMinutes += day.effective_minutes ?? 0;
    paidMinutes += day.paid_minutes ?? 0;
    travelMinutes += day.travel_minutes ?? 0;
  }

  return {
    worked_minutes: workedMinutes,
    expected_minutes: expectedMinutes,
    difference_minutes: workedMinutes - expectedMinutes,
    worked_days: workedDays,
    laborable_days: laborableDays,
    absence_days: absenceDays,
    overtime_minutes: overtimeMinutes,
    presence_minutes: hasEffectiveTime ? effectiveMinutes : undefined,
    effective_minutes: hasEffectiveTime ? effectiveMinutes : undefined,
    paid_minutes: hasEffectiveTime ? paidMinutes : undefined,
    travel_minutes: hasEffectiveTime ? travelMinutes : undefined,
    has_effective_time: hasEffectiveTime,
  };
}

export function isPeriodConfirmed(
  confirmations: Array<{ period_from: string; period_to: string }>,
  from: string,
  to: string,
): boolean {
  return confirmations.some((c) => c.period_from === from && c.period_to === to);
}

export function isPeriodEnded(periodTo: string): boolean {
  return periodTo < toIsoDate(new Date());
}
