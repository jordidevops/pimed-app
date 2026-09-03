import { createAdminClient } from "../supabase.ts";
import { recordAccessLog } from "./repository.ts";

export interface PortalScheduleDay {
  date: string;
  day_type: string;
  labor_day_type: string | null;
  expected_minutes: number;
  work_intervals: Array<{ start: string; end: string }>;
  holiday_name: string | null;
  is_holiday: boolean;
  is_absence: boolean;
  absence_type: string | null;
  labor_source: string | null;
}

export interface PortalScheduleAbsence {
  id: string;
  start_date: string;
  end_date: string;
  status: string;
  absence_type: string;
}

export interface PortalSchedulePayload {
  employee_id: string;
  tenant_id: string;
  from: string;
  to: string;
  days: PortalScheduleDay[];
  absences: PortalScheduleAbsence[];
}

function parsePortalBoolean(value: unknown): boolean {
  if (value === true || value === 1) return true;
  if (value === false || value === 0 || value == null) return false;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    return normalized === "true" || normalized === "t" || normalized === "1";
  }
  return false;
}

function mapDay(raw: Record<string, unknown>): PortalScheduleDay {
  const intervals = Array.isArray(raw.work_intervals)
    ? (raw.work_intervals as Array<{ start: string; end: string }>)
    : [];

  return {
    date: String(raw.date ?? ""),
    day_type: String(raw.day_type ?? "unknown"),
    labor_day_type: raw.labor_day_type != null ? String(raw.labor_day_type) : null,
    expected_minutes: Number(raw.expected_minutes ?? 0),
    work_intervals: intervals,
    holiday_name: raw.holiday_name != null ? String(raw.holiday_name) : null,
    is_holiday: parsePortalBoolean(raw.is_holiday),
    is_absence: parsePortalBoolean(raw.is_absence),
    absence_type: raw.absence_type != null ? String(raw.absence_type) : null,
    labor_source: raw.labor_source != null ? String(raw.labor_source) : null,
  };
}

export async function getPortalSchedule(
  employee_id: string,
  tenant_id: string,
  token_id: string,
  from: string,
  to: string,
): Promise<PortalSchedulePayload> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_get_schedule", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
    p_from: from,
    p_to: to,
  });

  if (error) {
    const message = error.message ?? "schedule_failed";
    if (message.includes("employee_not_found")) {
      throw new ScheduleError("employee_not_found", 404, message);
    }
    if (message.includes("invalid_date_range") || message.includes("date_range_too_large")) {
      throw new ScheduleError("invalid_date_range", 400, message);
    }
    throw new ScheduleError("schedule_failed", 500, message);
  }

  const payload = data as Record<string, unknown>;
  const daysRaw = Array.isArray(payload.days) ? payload.days : [];
  const absencesRaw = Array.isArray(payload.absences) ? payload.absences : [];

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "view_schedule",
    http_status: 200,
  }).catch(() => undefined);

  return {
    employee_id,
    tenant_id,
    from: String(payload.from ?? from),
    to: String(payload.to ?? to),
    days: daysRaw.map((d) => mapDay(d as Record<string, unknown>)),
    absences: absencesRaw.map((a) => {
      const row = a as Record<string, unknown>;
      return {
        id: String(row.id ?? ""),
        start_date: String(row.start_date ?? ""),
        end_date: String(row.end_date ?? ""),
        status: String(row.status ?? ""),
        absence_type: String(row.absence_type ?? ""),
      };
    }),
  };
}

export class ScheduleError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "ScheduleError";
  }
}
