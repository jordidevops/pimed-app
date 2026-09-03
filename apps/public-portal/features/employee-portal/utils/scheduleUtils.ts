export interface WorkInterval {
  start: string;
  end: string;
}

export function parseWorkIntervals(raw: unknown): WorkInterval[] {
  if (raw == null) return [];
  let data: unknown = raw;
  if (typeof raw === "string") {
    try {
      data = JSON.parse(raw);
    } catch {
      return [];
    }
  }
  if (!Array.isArray(data)) return [];
  return data
    .filter((x): x is Record<string, unknown> => x != null && typeof x === "object")
    .map((x) => ({
      start: normalizeTime(String(x.start ?? "")),
      end: normalizeTime(String(x.end ?? "")),
    }))
    .filter((x) => x.start && x.end);
}

function normalizeTime(t: string): string {
  const trimmed = t.trim();
  if (!trimmed) return "";
  const parts = trimmed.split(":");
  if (parts.length < 2) return trimmed.slice(0, 5);
  return `${parts[0].padStart(2, "0")}:${parts[1].padStart(2, "0")}`;
}

function isOvernight(start: string, end: string): boolean {
  const toMin = (hhmm: string) => {
    const [h, m] = hhmm.split(":").map(Number);
    return h * 60 + m;
  };
  return toMin(end) <= toMin(start);
}

export function formatInterval(iv: WorkInterval, overnightSuffix = " (+1)"): string {
  const overnight = isOvernight(iv.start, iv.end);
  return `${iv.start}–${iv.end}${overnight ? overnightSuffix : ""}`;
}

export function formatIntervalsList(intervals: WorkInterval[], overnightSuffix = " (+1)"): string {
  return intervals.map((iv) => formatInterval(iv, overnightSuffix)).join(", ");
}

/** Format curt per cel·les del calendari mensual (p. ex. «7–15» o «8:30–14, 15–17»). */
export function formatIntervalsCompact(intervals: WorkInterval[], overnightSuffix = ""): string {
  return intervals
    .map((iv) => {
      const overnight = isOvernight(iv.start, iv.end);
      return `${compactClock(iv.start)}–${compactClock(iv.end)}${overnight ? overnightSuffix : ""}`;
    })
    .join(", ");
}

function compactClock(hhmm: string): string {
  const [hRaw, mRaw] = hhmm.split(":");
  const h = Number(hRaw);
  const m = Number(mRaw);
  if (Number.isNaN(h) || Number.isNaN(m)) return hhmm.slice(0, 5);
  if (m === 0) return String(h);
  return `${h}:${String(m).padStart(2, "0")}`;
}

export function formatWorkDuration(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m} min`;
  if (m === 0) return `${h} h`;
  return `${h} h ${m} min`;
}

export function toIsoDate(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

export function monthRange(year: number, month: number): { from: string; to: string } {
  const from = toIsoDate(new Date(year, month, 1));
  const to = toIsoDate(new Date(year, month + 1, 0));
  return { from, to };
}

export function addDaysIso(isoDate: string, days: number): string {
  const d = new Date(`${isoDate}T12:00:00`);
  d.setDate(d.getDate() + days);
  return toIsoDate(d);
}

/** weekStartsOn: 0=Sunday, 1=Monday */
export function startOfWeekIso(isoDate: string, weekStartsOn = 1): string {
  const d = new Date(`${isoDate}T12:00:00`);
  const diff = (d.getDay() - weekStartsOn + 7) % 7;
  d.setDate(d.getDate() - diff);
  return toIsoDate(d);
}

export function weekRange(weekStartIso: string): { from: string; to: string; dates: string[] } {
  const dates = Array.from({ length: 7 }, (_, i) => addDaysIso(weekStartIso, i));
  return { from: dates[0]!, to: dates[6]!, dates };
}

export function formatWeekPeriodLabel(
  weekStartIso: string,
  locale: string,
  monthNames?: string[],
): string {
  const start = new Date(`${weekStartIso}T12:00:00`);
  const end = new Date(`${addDaysIso(weekStartIso, 6)}T12:00:00`);
  const sameMonth = start.getMonth() === end.getMonth() && start.getFullYear() === end.getFullYear();

  if (sameMonth && monthNames) {
    return `${start.getDate()}–${end.getDate()} ${monthNames[start.getMonth()]} ${start.getFullYear()}`;
  }

  const fmt = (d: Date) =>
    d.toLocaleDateString(locale, { day: "numeric", month: "short", year: "numeric" });
  return `${fmt(start)} – ${fmt(end)}`;
}
