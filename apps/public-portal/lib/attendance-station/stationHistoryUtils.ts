export type StationHistoryViewMode = "week" | "month";

export type StationHistoryDayRow = {
  id: string;
  work_date: string;
  starts_at: string | null;
  ends_at: string | null;
  net_minutes: number | null;
  status: string;
};

export type StationHistoryPunchRow = {
  id: string;
  punch_type: string;
  occurred_at: string;
  source: string | null;
};

function toIsoDate(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
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

export function getStationHistoryRange(
  mode: StationHistoryViewMode,
  refDate: Date,
  locale = "ca-ES",
): { from: string; to: string; label: string } {
  if (mode === "month") {
    const from = startOfMonth(refDate);
    const to = endOfMonth(refDate);
    return {
      from: toIsoDate(from),
      to: toIsoDate(to),
      label: from.toLocaleDateString(locale, { month: "long", year: "numeric" }),
    };
  }

  const from = startOfWeek(refDate);
  const to = endOfWeek(refDate);
  return {
    from: toIsoDate(from),
    to: toIsoDate(to),
    label: `${from.toLocaleDateString(locale, { day: "numeric", month: "short" })} – ${to.toLocaleDateString(locale, { day: "numeric", month: "short" })}`,
  };
}

export function navigateStationHistory(
  mode: StationHistoryViewMode,
  refDate: Date,
  direction: -1 | 1,
): Date {
  const next = new Date(refDate);
  if (mode === "month") {
    next.setMonth(next.getMonth() + direction);
  } else {
    next.setDate(next.getDate() + direction * 7);
  }
  return next;
}

function punchWorkDate(occurredAt: string, timeZone: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone }).format(new Date(occurredAt));
}

function buildRowsFromPunches(
  punches: StationHistoryPunchRow[],
  timeZone: string,
): StationHistoryDayRow[] {
  const byDate = new Map<string, StationHistoryPunchRow[]>();

  for (const punch of punches) {
    if (!punch.occurred_at) continue;
    const workDate = punchWorkDate(punch.occurred_at, timeZone);
    const list = byDate.get(workDate) ?? [];
    list.push(punch);
    byDate.set(workDate, list);
  }

  const rows: StationHistoryDayRow[] = [];
  for (const [workDate, dayPunches] of byDate) {
    dayPunches.sort((a, b) => a.occurred_at.localeCompare(b.occurred_at));
    const firstIn = dayPunches.find((p) => p.punch_type === "in");
    const lastOut = [...dayPunches].reverse().find((p) => p.punch_type === "out");
    let netMinutes: number | null = null;
    if (firstIn?.occurred_at && lastOut?.occurred_at) {
      netMinutes = Math.max(
        0,
        Math.round(
          (new Date(lastOut.occurred_at).getTime() - new Date(firstIn.occurred_at).getTime()) /
            60_000,
        ),
      );
    }
    rows.push({
      id: `punch-summary-${workDate}`,
      work_date: workDate,
      starts_at: firstIn?.occurred_at ?? null,
      ends_at: lastOut?.occurred_at ?? null,
      net_minutes: netMinutes,
      status: lastOut ? "closed" : firstIn ? "open" : "missing",
    });
  }

  return rows.sort((a, b) => b.work_date.localeCompare(a.work_date));
}

export function mergeStationHistoryDays(
  entries: StationHistoryDayRow[],
  punches: StationHistoryPunchRow[],
  timeZone: string,
): StationHistoryDayRow[] {
  if (entries.length > 0) {
    const entryDates = new Set(entries.map((e) => e.work_date));
    const punchOnly = buildRowsFromPunches(
      punches.filter((p) => !entryDates.has(punchWorkDate(p.occurred_at, timeZone))),
      timeZone,
    );
    return [...entries, ...punchOnly].sort((a, b) => b.work_date.localeCompare(a.work_date));
  }
  return buildRowsFromPunches(punches, timeZone);
}

export function formatStationHistoryTime(iso: string | null, timeZone: string): string {
  if (!iso) return "—";
  return new Intl.DateTimeFormat("ca-ES", {
    hour: "2-digit",
    minute: "2-digit",
    timeZone,
  }).format(new Date(iso));
}

export function formatStationNetMinutes(minutes: number | null): string {
  if (minutes == null) return "—";
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return `${h}h ${String(m).padStart(2, "0")}m`;
}
