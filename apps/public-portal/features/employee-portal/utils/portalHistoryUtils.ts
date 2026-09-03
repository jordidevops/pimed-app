import { addDaysIso, toIsoDate } from "./scheduleUtils";

export const PORTAL_HISTORY_DAYS = 28;

export type PortalHistoryViewMode = "day" | "week" | "month";

export interface PortalHistoryDay {
  id: string;
  work_date: string;
  starts_at: string | null;
  ends_at: string | null;
  net_minutes: number | null;
  status: string;
}

function startOfWeek(d: Date): Date {
  const day = d.getDay();
  const diff = day === 0 ? -6 : 1 - day;
  const r = new Date(d);
  r.setDate(d.getDate() + diff);
  r.setHours(12, 0, 0, 0);
  return r;
}

function endOfWeek(d: Date): Date {
  const start = startOfWeek(d);
  const end = new Date(start);
  end.setDate(start.getDate() + 6);
  return end;
}

function startOfMonth(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), 1, 12, 0, 0, 0);
}

function endOfMonth(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth() + 1, 0, 12, 0, 0, 0);
}

export function historyWindowStart(): string {
  return addDaysIso(toIsoDate(new Date()), -(PORTAL_HISTORY_DAYS - 1));
}

export function historyWindowEnd(): string {
  return toIsoDate(new Date());
}

export function clampHistoryRange(from: string, to: string): { from: string; to: string } {
  const min = historyWindowStart();
  const max = historyWindowEnd();
  return {
    from: from < min ? min : from,
    to: to > max ? max : to,
  };
}

export function getHistoryRangeForMode(
  mode: PortalHistoryViewMode,
  ref: Date,
  locale: string,
): { from: string; to: string; label: string } {
  if (mode === "day") {
    const iso = toIsoDate(ref);
    return {
      from: iso,
      to: iso,
      label: ref.toLocaleDateString(locale, { weekday: "long", day: "numeric", month: "long" }),
    };
  }
  if (mode === "week") {
    const start = startOfWeek(ref);
    const end = endOfWeek(ref);
    return {
      from: toIsoDate(start),
      to: toIsoDate(end),
      label: `${start.toLocaleDateString(locale, { day: "numeric", month: "short" })} – ${end.toLocaleDateString(locale, { day: "numeric", month: "short", year: "numeric" })}`,
    };
  }
  const start = startOfMonth(ref);
  const end = endOfMonth(ref);
  return {
    from: toIsoDate(start),
    to: toIsoDate(end),
    label: ref.toLocaleDateString(locale, { month: "long", year: "numeric" }),
  };
}

export function navigateHistory(mode: PortalHistoryViewMode, ref: Date, direction: 1 | -1): Date {
  const d = new Date(ref);
  if (mode === "day") d.setDate(d.getDate() + direction);
  else if (mode === "week") d.setDate(d.getDate() + direction * 7);
  else d.setMonth(d.getMonth() + direction);
  return d;
}

export function canNavigateHistoryPrev(mode: PortalHistoryViewMode, ref: Date): boolean {
  const { from } = getHistoryRangeForMode(mode, navigateHistory(mode, ref, -1), "ca-ES");
  return from >= historyWindowStart();
}

export function canNavigateHistoryNext(mode: PortalHistoryViewMode, ref: Date): boolean {
  const { to } = getHistoryRangeForMode(mode, navigateHistory(mode, ref, 1), "ca-ES");
  return to <= historyWindowEnd();
}

export function formatHistoryTime(iso: string | null | undefined, locale: string): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleTimeString(locale, { hour: "2-digit", minute: "2-digit" });
}

export function formatNetMinutes(minutes: number | null | undefined): { hours: number; mins: number } {
  const total = minutes ?? 0;
  return { hours: Math.floor(total / 60), mins: total % 60 };
}

export const HISTORY_STATUS_CLASS: Record<string, string> = {
  open: "bg-amber-100 text-amber-800 dark:bg-amber-950/40 dark:text-amber-200",
  closed: "bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-200",
  adjusted: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200",
  missing: "bg-red-100 text-red-800 dark:bg-red-950/40 dark:text-red-200",
  approved: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200",
  anomaly: "bg-red-100 text-red-800 dark:bg-red-950/40 dark:text-red-200",
};
