import type { PortalScheduleAbsence, PortalScheduleDay } from "../api/portalApi";

export type ScheduleDayKind = "work" | "holiday" | "vacation" | "non_working" | "unknown";

export interface ScheduleDayStyle {
  labelKey: string;
  cell: string;
  legend: string;
}

export const SCHEDULE_DAY_STYLE: Record<ScheduleDayKind, ScheduleDayStyle> = {
  work: {
    labelKey: "schedule.type_work",
    cell: "bg-emerald-200/90 border-l-[3px] border-l-emerald-700 text-emerald-950",
    legend: "bg-emerald-600",
  },
  holiday: {
    labelKey: "schedule.type_holiday",
    cell: "bg-red-200/90 border-l-[3px] border-l-red-700 text-red-950",
    legend: "bg-red-600",
  },
  vacation: {
    labelKey: "schedule.type_vacation",
    cell: "bg-sky-200/90 border-l-[3px] border-l-sky-700 text-sky-950",
    legend: "bg-sky-600",
  },
  non_working: {
    labelKey: "schedule.type_non_working",
    cell: "bg-muted/60 border-l-[3px] border-l-muted-foreground/40 text-muted-foreground",
    legend: "bg-muted-foreground/50",
  },
  unknown: {
    labelKey: "schedule.type_unknown",
    cell: "bg-background border border-border text-muted-foreground",
    legend: "bg-border",
  },
};

export const ABSENCE_RING: Record<string, string> = {
  approved: "ring-2 ring-inset ring-violet-600",
  requested: "ring-2 ring-inset ring-dashed ring-violet-400",
  rejected: "ring-1 ring-inset ring-red-300 opacity-60",
  cancelled: "opacity-50",
};

export function isPortalScheduleWorkDay(day: PortalScheduleDay): boolean {
  return day.labor_day_type === "work" || day.day_type === "working";
}

/** Matches api.resolve_work_day: festiu assignat o tipus holiday, incl. jornada en festiu. */
export function isPortalScheduleHolidayDay(day: PortalScheduleDay): boolean {
  if (day.labor_day_type === "holiday") return true;
  if (day.day_type === "holiday" || day.day_type === "half_holiday") return true;
  if (day.is_holiday && isPortalScheduleWorkDay(day)) return true;
  if (day.is_holiday && day.labor_source === "assigned_holiday") return true;
  return false;
}

export function resolveScheduleDayKind(day: PortalScheduleDay | undefined): ScheduleDayKind {
  if (!day) return "unknown";
  if (day.is_absence) return "vacation";
  if (isPortalScheduleHolidayDay(day)) return "holiday";
  if (isPortalScheduleWorkDay(day)) return "work";
  if (day.labor_day_type === "vacation") return "vacation";
  if (day.labor_day_type === "leave" || day.day_type === "non_working") return "non_working";
  return "unknown";
}

export function findAbsenceForDate(
  date: string,
  absences: PortalScheduleAbsence[],
): PortalScheduleAbsence | undefined {
  return absences.find((a) => a.start_date <= date && a.end_date >= date);
}

export function buildMonthGrid(year: number, month: number, weekStartsOn = 1): (string | null)[] {
  const first = new Date(year, month, 1);
  const lastDay = new Date(year, month + 1, 0).getDate();
  const jsDow = first.getDay();
  const offset = (jsDow - weekStartsOn + 7) % 7;

  const cells: (string | null)[] = Array.from({ length: offset }, () => null);
  for (let d = 1; d <= lastDay; d++) {
    const iso = `${year}-${String(month + 1).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
    cells.push(iso);
  }
  while (cells.length % 7 !== 0) cells.push(null);
  return cells;
}
