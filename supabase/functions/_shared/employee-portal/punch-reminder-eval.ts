import {
  computeWorkScheduleStatus,
  getSchedulePhase,
  type PunchPresenceStatus,
  type WorkInterval,
  type WorkScheduleDayInput,
  type WorkSchedulePunchInput,
} from "./work-schedule-status.ts";

export type PunchReminderKind =
  | "missing_entry"
  | "missing_afternoon_entry"
  | "missing_morning_exit"
  | "missing_exit"
  | "starting_soon"
  | "afternoon_starting_soon";

export interface PunchReminderConfig {
  enabled: boolean;
  delayMinutes: number;
  soonThresholdMinutes: number;
  sendStartingSoon: boolean;
  sendOnlyOnWorkdays: boolean;
  maxPerDay: number;
}

export const DEFAULT_PUNCH_REMINDER_CONFIG: PunchReminderConfig = {
  enabled: false,
  delayMinutes: 5,
  soonThresholdMinutes: 15,
  sendStartingSoon: false,
  sendOnlyOnWorkdays: true,
  maxPerDay: 4,
};

const TITLE_KEY_TO_KIND: Record<string, PunchReminderKind> = {
  "work_status.missing_entry": "missing_entry",
  "work_status.missing_afternoon_entry": "missing_afternoon_entry",
  "work_status.missing_morning_exit": "missing_morning_exit",
  "work_status.missing_exit": "missing_exit",
  "work_status.starting_soon": "starting_soon",
  "work_status.afternoon_starting_soon": "afternoon_starting_soon",
};

export function parsePunchReminderConfig(raw: unknown): PunchReminderConfig {
  if (!raw || typeof raw !== "object") return { ...DEFAULT_PUNCH_REMINDER_CONFIG };
  const o = raw as Record<string, unknown>;
  return {
    enabled: o.enabled === true,
    delayMinutes: clampInt(o.delay_minutes, 1, 120, DEFAULT_PUNCH_REMINDER_CONFIG.delayMinutes),
    soonThresholdMinutes: clampInt(
      o.soon_threshold_minutes,
      1,
      60,
      DEFAULT_PUNCH_REMINDER_CONFIG.soonThresholdMinutes,
    ),
    sendStartingSoon: o.send_starting_soon === true,
    sendOnlyOnWorkdays: o.send_only_on_workdays !== false,
    maxPerDay: clampInt(o.max_per_day, 1, 10, DEFAULT_PUNCH_REMINDER_CONFIG.maxPerDay),
  };
}

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.floor(n)));
}

function parseTimeOnDate(timeStr: string, base: Date): Date {
  const [h, m] = timeStr.split(":").map(Number);
  const d = new Date(base);
  d.setHours(h, m, 0, 0);
  return d;
}

function addMinutes(d: Date, minutes: number): Date {
  return new Date(d.getTime() + minutes * 60_000);
}

function reminderDueAt(
  kind: PunchReminderKind,
  intervals: WorkInterval[],
  now: Date,
  delayMinutes: number,
): Date | null {
  const phase = getSchedulePhase(intervals, now);

  switch (kind) {
    case "missing_entry": {
      if (phase.phase !== "slot" || phase.index !== 0) return null;
      return addMinutes(parseTimeOnDate(intervals[0]!.start, now), delayMinutes);
    }
    case "missing_afternoon_entry": {
      if (phase.phase !== "slot" || phase.index <= 0) return null;
      return addMinutes(parseTimeOnDate(intervals[phase.index]!.start, now), delayMinutes);
    }
    case "missing_morning_exit": {
      if (phase.phase !== "break") return null;
      return addMinutes(
        parseTimeOnDate(intervals[phase.afterIndex]!.end, now),
        delayMinutes,
      );
    }
    case "missing_exit": {
      if (phase.phase !== "after" || intervals.length === 0) return null;
      const last = intervals[intervals.length - 1]!;
      const endAt = parseTimeOnDate(last.end, now);
      const startAt = parseTimeOnDate(last.start, now);
      if (endAt.getTime() <= startAt.getTime()) {
        return addMinutes(new Date(endAt.getTime() + 24 * 60 * 60 * 1000), delayMinutes);
      }
      return addMinutes(endAt, delayMinutes);
    }
    case "starting_soon":
    case "afternoon_starting_soon":
      return now;
    default:
      return null;
  }
}

export interface EvaluatePunchReminderParams {
  schedule: WorkScheduleDayInput;
  punches: WorkSchedulePunchInput[];
  presenceStatus: PunchPresenceStatus;
  now: Date;
  config: PunchReminderConfig;
}

export function evaluatePunchReminder(
  params: EvaluatePunchReminderParams,
): PunchReminderKind | null {
  const { schedule, punches, presenceStatus, now, config } = params;

  const status = computeWorkScheduleStatus({
    schedule,
    punches,
    presenceStatus,
    now,
    soonThresholdMinutes: config.soonThresholdMinutes,
  });

  if (!status) return null;

  const kind = TITLE_KEY_TO_KIND[status.titleKey];
  if (!kind) return null;

  if ((kind === "starting_soon" || kind === "afternoon_starting_soon") && !config.sendStartingSoon) {
    return null;
  }

  if (kind === "starting_soon" || kind === "afternoon_starting_soon") {
    return kind;
  }

  const dueAt = reminderDueAt(kind, schedule.intervals, now, config.delayMinutes);
  if (!dueAt) return null;
  if (now.getTime() < dueAt.getTime()) return null;

  return kind;
}

export function workDateInTimezone(now: Date, timezone: string): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
}

export function localNowInTimezone(now: Date, timezone: string): Date {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).formatToParts(now);

  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "0";
  return new Date(
    Number(get("year")),
    Number(get("month")) - 1,
    Number(get("day")),
    Number(get("hour")),
    Number(get("minute")),
    Number(get("second")),
  );
}

export function mapResolveWorkDayToScheduleInput(resolve: Record<string, unknown>): WorkScheduleDayInput {
  const intervalsRaw = resolve.work_intervals;
  const intervals: WorkInterval[] = Array.isArray(intervalsRaw)
    ? intervalsRaw
      .filter((iv): iv is Record<string, string> => !!iv && typeof iv === "object")
      .map((iv) => ({
        start: String(iv.start ?? "").slice(0, 5),
        end: String(iv.end ?? "").slice(0, 5),
      }))
      .filter((iv) => iv.start && iv.end)
    : [];

  return {
    dayType: String(resolve.day_type ?? resolve.dayType ?? "unknown"),
    laborDayType: resolve.labor_day_type != null ? String(resolve.labor_day_type) : null,
    intervals,
    holidayName: resolve.holiday_name != null ? String(resolve.holiday_name) : null,
    isHoliday: resolve.is_holiday === true || resolve.isHoliday === true,
    isAbsence: resolve.is_absence === true || resolve.isAbsence === true,
  };
}
