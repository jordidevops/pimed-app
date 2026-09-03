import { createAdminClient } from "../supabase.ts";
import { recordAccessLog } from "./repository.ts";

export interface PortalMonthlyReportDay {
  work_date: string;
  starts_at: string | null;
  ends_at: string | null;
  break_minutes: number | null;
  net_minutes: number | null;
  status: string | null;
  anomaly_codes: string[];
}

export interface PortalMonthlyCalendarDay {
  work_date: string;
  day_type: string | null;
  expected_minutes: number;
  worked_minutes: number;
  overtime_minutes: number;
  balance_minutes: number;
  is_laborable: boolean;
  holiday_name: string | null;
  starts_at: string | null;
  ends_at: string | null;
  net_minutes: number | null;
  break_minutes: number | null;
  presence_minutes?: number | null;
  work_minutes?: number | null;
  travel_minutes?: number | null;
  effective_minutes?: number | null;
  paid_minutes?: number | null;
  overtime_authorized_minutes?: number | null;
  work_profile_snapshot?: string | null;
  absence_id: string | null;
  absence_type: string | null;
  absence_status: string | null;
  is_it: boolean;
  entry_status: string | null;
  summary_status: string | null;
  payroll_action: string | null;
}

export interface PortalMonthlyReportSummary {
  worked_minutes: number;
  expected_minutes: number;
  difference_minutes: number;
  worked_days: number;
  laborable_days: number;
  absence_days: number;
  overtime_minutes: number;
  presence_minutes?: number;
  effective_minutes?: number;
  paid_minutes?: number;
  travel_minutes?: number;
  has_effective_time?: boolean;
}

export interface PortalMonthlyReportExport {
  employee_id: string;
  employee_name: string;
  year: number;
  month: number;
  days: PortalMonthlyReportDay[];
  summary: {
    worked_minutes: number;
    expected_minutes: number;
    difference_minutes: number;
  };
  generated_at: string;
}

export interface PortalMonthlyCloseIssue {
  code: string;
  count?: number;
  work_date?: string;
  work_dates?: string[];
}

export interface PortalPeriodConfirmation {
  id: string;
  period_from: string;
  period_to: string;
  cycle_type: string;
  calendar_year: number;
  calendar_month: number;
  confirmed_at: string;
  confirmed_via: string;
}

export interface PortalMonthPeriodStatus {
  cycle: "calendar_month" | "iso_week";
  month_from: string;
  month_to: string;
  confirmations: PortalPeriodConfirmation[];
  weeks_required: number;
  weeks_confirmed: number;
  month_period_confirmed: boolean;
  month_fully_confirmed: boolean;
}

export interface PortalMonthlyReportPayload {
  employee_id: string;
  tenant_id: string;
  year: number;
  month: number;
  employee_name: string;
  employee_email: string | null;
  report: {
    id: string | null;
    status: string;
    confirmed_at: string | null;
    approved_at: string | null;
    signing_submission_id: string | null;
    document_id: string | null;
    content_hash: string | null;
  };
  export: PortalMonthlyReportExport;
  calendar_days: PortalMonthlyCalendarDay[];
  summary: PortalMonthlyReportSummary;
  settings: {
    employee_confirm_required: boolean;
    require_digital_signature: boolean;
    signature_is_employee_approval: boolean;
    employee_confirm_cycle: "calendar_month" | "iso_week";
  };
  validation: {
    confirmable: boolean;
    blockers: PortalMonthlyCloseIssue[];
    period?: { from: string; to: string };
  };
  period_validation?: {
    confirmable: boolean;
    blockers: PortalMonthlyCloseIssue[];
    period?: { from: string; to: string };
  };
  period_status: PortalMonthPeriodStatus;
  signing: {
    submission_id: string;
    status: string;
    signers: unknown;
  } | null;
  employee_sign_url: string | null;
}

type SignerRow = {
  role?: string;
  email?: string;
  signing_url?: string | null;
  status?: string;
  order?: number;
};

function parseSigners(raw: unknown): SignerRow[] {
  if (!Array.isArray(raw)) return [];
  return raw as SignerRow[];
}

function isPendingSigner(s: SignerRow): boolean {
  const status = (s.status ?? "").toLowerCase();
  return status !== "completed" && status !== "signed" && !!s.signing_url;
}

export function resolvePortalEmployeeSignerLink(
  signersRaw: unknown,
  employeeEmail?: string | null,
): string | null {
  const signers = parseSigners(signersRaw);
  if (!signers.length) return null;

  const emailLower = employeeEmail?.trim().toLowerCase();

  for (const s of signers) {
    const role = (s.role ?? "").toLowerCase();
    const isEmployeeRole =
      role === "empleat" || role === "employee" || role === "treballador" || role === "worker";
    const emailMatch = emailLower && s.email?.toLowerCase() === emailLower;
    if ((isEmployeeRole || emailMatch) && isPendingSigner(s)) {
      return s.signing_url!;
    }
  }

  const sorted = [...signers].sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
  return sorted.find(isPendingSigner)?.signing_url ?? null;
}

function mapExport(raw: Record<string, unknown>): PortalMonthlyReportExport {
  const daysRaw = Array.isArray(raw.days) ? raw.days : [];
  const summary = (raw.summary ?? {}) as Record<string, unknown>;

  return {
    employee_id: String(raw.employee_id ?? ""),
    employee_name: String(raw.employee_name ?? ""),
    year: Number(raw.year ?? 0),
    month: Number(raw.month ?? 0),
    days: daysRaw.map((d) => {
      const row = d as Record<string, unknown>;
      return {
        work_date: String(row.work_date ?? ""),
        starts_at: row.starts_at != null ? String(row.starts_at) : null,
        ends_at: row.ends_at != null ? String(row.ends_at) : null,
        break_minutes: row.break_minutes != null ? Number(row.break_minutes) : null,
        net_minutes: row.net_minutes != null ? Number(row.net_minutes) : null,
        status: row.status != null ? String(row.status) : null,
        anomaly_codes: Array.isArray(row.anomaly_codes)
          ? (row.anomaly_codes as string[])
          : [],
      };
    }),
    summary: {
      worked_minutes: Number(summary.worked_minutes ?? 0),
      expected_minutes: Number(summary.expected_minutes ?? 0),
      difference_minutes: Number(summary.difference_minutes ?? 0),
      presence_minutes: summary.presence_minutes != null ? Number(summary.presence_minutes) : undefined,
      effective_minutes: summary.effective_minutes != null ? Number(summary.effective_minutes) : undefined,
      paid_minutes: summary.paid_minutes != null ? Number(summary.paid_minutes) : undefined,
      travel_minutes: summary.travel_minutes != null ? Number(summary.travel_minutes) : undefined,
      overtime_minutes: summary.overtime_minutes != null ? Number(summary.overtime_minutes) : undefined,
      has_effective_time: summary.has_effective_time === true,
    },
    generated_at: String(raw.generated_at ?? new Date().toISOString()),
  };
}

function mapCalendarDay(raw: Record<string, unknown>): PortalMonthlyCalendarDay {
  return {
    work_date: String(raw.work_date ?? ""),
    day_type: raw.day_type != null ? String(raw.day_type) : null,
    expected_minutes: Number(raw.expected_minutes ?? 0),
    worked_minutes: Number(raw.worked_minutes ?? 0),
    overtime_minutes: Number(raw.overtime_minutes ?? 0),
    balance_minutes: Number(raw.balance_minutes ?? 0),
    is_laborable: Boolean(raw.is_laborable ?? false),
    holiday_name: raw.holiday_name != null ? String(raw.holiday_name) : null,
    starts_at: raw.starts_at != null ? String(raw.starts_at) : null,
    ends_at: raw.ends_at != null ? String(raw.ends_at) : null,
    net_minutes: raw.net_minutes != null ? Number(raw.net_minutes) : null,
    break_minutes: raw.break_minutes != null ? Number(raw.break_minutes) : null,
    presence_minutes: raw.presence_minutes != null ? Number(raw.presence_minutes) : null,
    work_minutes: raw.work_minutes != null ? Number(raw.work_minutes) : null,
    travel_minutes: raw.travel_minutes != null ? Number(raw.travel_minutes) : null,
    effective_minutes: raw.effective_minutes != null ? Number(raw.effective_minutes) : null,
    paid_minutes: raw.paid_minutes != null ? Number(raw.paid_minutes) : null,
    overtime_authorized_minutes:
      raw.overtime_authorized_minutes != null ? Number(raw.overtime_authorized_minutes) : null,
    work_profile_snapshot:
      raw.work_profile_snapshot != null ? String(raw.work_profile_snapshot) : null,
    absence_id: raw.absence_id != null ? String(raw.absence_id) : null,
    absence_type: raw.absence_type != null ? String(raw.absence_type) : null,
    absence_status: raw.absence_status != null ? String(raw.absence_status) : null,
    is_it: Boolean(raw.is_it ?? false),
    entry_status: raw.entry_status != null ? String(raw.entry_status) : null,
    summary_status: raw.summary_status != null ? String(raw.summary_status) : null,
    payroll_action: raw.payroll_action != null ? String(raw.payroll_action) : null,
  };
}

function mapSummary(raw: Record<string, unknown> | undefined): PortalMonthlyReportSummary {
  const s = raw ?? {};
  return {
    worked_minutes: Number(s.worked_minutes ?? 0),
    expected_minutes: Number(s.expected_minutes ?? 0),
    difference_minutes: Number(s.difference_minutes ?? 0),
    worked_days: Number(s.worked_days ?? 0),
    laborable_days: Number(s.laborable_days ?? 0),
    absence_days: Number(s.absence_days ?? 0),
    overtime_minutes: Number(s.overtime_minutes ?? 0),
    presence_minutes: s.presence_minutes != null ? Number(s.presence_minutes) : undefined,
    effective_minutes: s.effective_minutes != null ? Number(s.effective_minutes) : undefined,
    paid_minutes: s.paid_minutes != null ? Number(s.paid_minutes) : undefined,
    travel_minutes: s.travel_minutes != null ? Number(s.travel_minutes) : undefined,
    has_effective_time: s.has_effective_time === true,
  };
}

function mapBlockers(raw: unknown): PortalMonthlyCloseIssue[] {
  if (!Array.isArray(raw)) return [];
  return raw.map((item) => {
    const row = item as Record<string, unknown>;
    return {
      code: String(row.code ?? ""),
      count: row.count != null ? Number(row.count) : undefined,
      work_date: row.work_date != null ? String(row.work_date) : undefined,
      work_dates: Array.isArray(row.work_dates) ? (row.work_dates as string[]) : undefined,
    };
  });
}

function mapPeriodConfirmation(raw: Record<string, unknown>): PortalPeriodConfirmation {
  return {
    id: String(raw.id ?? ""),
    period_from: String(raw.period_from ?? ""),
    period_to: String(raw.period_to ?? ""),
    cycle_type: String(raw.cycle_type ?? ""),
    calendar_year: Number(raw.calendar_year ?? 0),
    calendar_month: Number(raw.calendar_month ?? 0),
    confirmed_at: String(raw.confirmed_at ?? ""),
    confirmed_via: String(raw.confirmed_via ?? ""),
  };
}

function mapPeriodStatus(raw: Record<string, unknown> | undefined): PortalMonthPeriodStatus {
  const row = raw ?? {};
  const cycleRaw = String(row.cycle ?? "calendar_month");
  const cycle = cycleRaw === "iso_week" ? "iso_week" : "calendar_month";
  const confirmationsRaw = Array.isArray(row.confirmations) ? row.confirmations : [];

  return {
    cycle,
    month_from: String(row.month_from ?? ""),
    month_to: String(row.month_to ?? ""),
    confirmations: confirmationsRaw.map((c) =>
      mapPeriodConfirmation(c as Record<string, unknown>)
    ),
    weeks_required: Number(row.weeks_required ?? 0),
    weeks_confirmed: Number(row.weeks_confirmed ?? 0),
    month_period_confirmed: Boolean(row.month_period_confirmed ?? false),
    month_fully_confirmed: Boolean(row.month_fully_confirmed ?? false),
  };
}

export async function getPortalMonthlyReport(
  employee_id: string,
  tenant_id: string,
  token_id: string,
  year: number,
  month: number,
  periodFrom?: string,
  periodTo?: string,
): Promise<PortalMonthlyReportPayload> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_get_monthly_report", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
    p_year: year,
    p_month: month,
  });

  if (error) {
    const message = error.message ?? "monthly_report_failed";
    if (message.includes("employee_not_found")) {
      throw new MonthlyReportError("employee_not_found", 404, message);
    }
    if (message.includes("invalid_month")) {
      throw new MonthlyReportError("invalid_month", 400, message);
    }
    throw new MonthlyReportError("monthly_report_failed", 500, message);
  }

  const payload = data as Record<string, unknown>;
  const reportRaw = (payload.report ?? {}) as Record<string, unknown>;
  const settingsRaw = (payload.settings ?? {}) as Record<string, unknown>;
  const validationRaw = (payload.validation ?? {}) as Record<string, unknown>;
  const signingRaw = payload.signing as Record<string, unknown> | null;
  const calendarRaw = Array.isArray(payload.calendar_days) ? payload.calendar_days : [];
  const periodStatusRaw = (payload.period_status ?? {}) as Record<string, unknown>;
  const employeeEmail = payload.employee_email != null ? String(payload.employee_email) : null;

  const employeeSignUrl = signingRaw
    ? resolvePortalEmployeeSignerLink(signingRaw.signers, employeeEmail)
    : null;

  let periodValidation: PortalMonthlyReportPayload["period_validation"];
  if (periodFrom && periodTo) {
    const { data: periodValidationRaw, error: periodValidationError } = await db.rpc(
      "employee_portal_validate_period",
      {
        p_employee_id: employee_id,
        p_tenant_id: tenant_id,
        p_period_from: periodFrom,
        p_period_to: periodTo,
      },
    );

    if (!periodValidationError && periodValidationRaw) {
      const pv = periodValidationRaw as Record<string, unknown>;
      periodValidation = {
        confirmable: Boolean(pv.confirmable ?? false),
        blockers: mapBlockers(pv.blockers),
        period: pv.period as { from: string; to: string } | undefined,
      };
    }
  }

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "view_monthly_report",
    http_status: 200,
  }).catch(() => undefined);

  return {
    employee_id,
    tenant_id,
    year: Number(payload.year ?? year),
    month: Number(payload.month ?? month),
    employee_name: String(payload.employee_name ?? ""),
    employee_email: employeeEmail,
    report: {
      id: reportRaw.id != null ? String(reportRaw.id) : null,
      status: String(reportRaw.status ?? "draft"),
      confirmed_at: reportRaw.confirmed_at != null ? String(reportRaw.confirmed_at) : null,
      approved_at: reportRaw.approved_at != null ? String(reportRaw.approved_at) : null,
      signing_submission_id: reportRaw.signing_submission_id != null
        ? String(reportRaw.signing_submission_id)
        : null,
      document_id: reportRaw.document_id != null ? String(reportRaw.document_id) : null,
      content_hash: reportRaw.content_hash != null ? String(reportRaw.content_hash) : null,
    },
    export: mapExport((payload.export ?? {}) as Record<string, unknown>),
    calendar_days: calendarRaw.map((d) => mapCalendarDay(d as Record<string, unknown>)),
    summary: mapSummary(payload.summary as Record<string, unknown> | undefined),
    settings: {
      employee_confirm_required: Boolean(settingsRaw.employee_confirm_required ?? true),
      require_digital_signature: Boolean(settingsRaw.require_digital_signature ?? false),
      signature_is_employee_approval: Boolean(settingsRaw.signature_is_employee_approval ?? false),
      employee_confirm_cycle:
        settingsRaw.employee_confirm_cycle === "iso_week" ? "iso_week" : "calendar_month",
    },
    validation: {
      confirmable: Boolean(validationRaw.confirmable ?? false),
      blockers: mapBlockers(validationRaw.blockers),
      period: validationRaw.period as { from: string; to: string } | undefined,
    },
    period_validation: periodValidation,
    period_status: mapPeriodStatus(periodStatusRaw),
    signing: signingRaw
      ? {
        submission_id: String(signingRaw.submission_id ?? ""),
        status: String(signingRaw.status ?? ""),
        signers: signingRaw.signers,
      }
      : null,
    employee_sign_url: employeeSignUrl,
  };
}

export async function confirmPortalMonthlyReport(
  employee_id: string,
  tenant_id: string,
  token_id: string,
  year: number,
  month: number,
): Promise<{ report_id: string }> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_confirm_monthly_report", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
    p_year: year,
    p_month: month,
  });

  if (error) {
    const message = error.message ?? "monthly_confirm_failed";
    if (message.includes("employee_not_found")) {
      throw new MonthlyReportError("employee_not_found", 404, message);
    }
    if (message.includes("employee_confirm_via_signature_required")) {
      throw new MonthlyReportError("employee_confirm_via_signature_required", 400, message);
    }
    if (message.includes("digital_signature_required")) {
      throw new MonthlyReportError("digital_signature_required", 400, message);
    }
    if (message.includes("already_confirmed")) {
      throw new MonthlyReportError("already_confirmed", 409, message);
    }
    if (message.includes("month_not_confirmable")) {
      throw new MonthlyReportError("month_not_confirmable", 400, message);
    }
    if (message.includes("employee_confirm_cycle_requires_weekly")) {
      throw new MonthlyReportError("employee_confirm_cycle_requires_weekly", 400, message);
    }
    if (message.includes("invalid_month")) {
      throw new MonthlyReportError("invalid_month", 400, message);
    }
    throw new MonthlyReportError("monthly_confirm_failed", 500, message);
  }

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "monthly_confirm",
    http_status: 200,
    metadata: {
      year,
      month,
      period_from: `${year}-${String(month).padStart(2, "0")}-01`,
      period_to: new Date(year, month, 0).toISOString().slice(0, 10),
      cycle_type: "calendar_month",
    },
  }).catch(() => undefined);

  return { report_id: String(data) };
}

export async function confirmPortalPeriodReport(
  employee_id: string,
  tenant_id: string,
  token_id: string,
  period_from: string,
  period_to: string,
  calendar_year: number,
  calendar_month: number,
): Promise<{ confirmation_id: string }> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_confirm_period_report", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
    p_period_from: period_from,
    p_period_to: period_to,
    p_calendar_year: calendar_year,
    p_calendar_month: calendar_month,
  });

  if (error) {
    const message = error.message ?? "period_confirm_failed";
    if (message.includes("employee_not_found")) {
      throw new MonthlyReportError("employee_not_found", 404, message);
    }
    if (message.includes("employee_confirm_via_signature_required")) {
      throw new MonthlyReportError("employee_confirm_via_signature_required", 400, message);
    }
    if (message.includes("digital_signature_required")) {
      throw new MonthlyReportError("digital_signature_required", 400, message);
    }
    if (message.includes("period_already_confirmed")) {
      throw new MonthlyReportError("period_already_confirmed", 409, message);
    }
    if (message.includes("period_not_confirmable")) {
      throw new MonthlyReportError("period_not_confirmable", 400, message);
    }
    if (message.includes("invalid_period_for_cycle")) {
      throw new MonthlyReportError("invalid_period_for_cycle", 400, message);
    }
    if (message.includes("invalid_period_range")) {
      throw new MonthlyReportError("invalid_period_range", 400, message);
    }
    throw new MonthlyReportError("period_confirm_failed", 500, message);
  }

  await recordAccessLog({
    token_id,
    employee_id,
    tenant_id,
    action: "period_confirm",
    http_status: 200,
    metadata: {
      period_from,
      period_to,
      calendar_year,
      calendar_month,
      cycle_type: "iso_week",
    },
  }).catch(() => undefined);

  return { confirmation_id: String(data) };
}

export class MonthlyReportError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "MonthlyReportError";
  }
}
