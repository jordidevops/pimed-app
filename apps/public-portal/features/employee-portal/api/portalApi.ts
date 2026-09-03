import { EMPLOYEE_PORTAL_API_BASE } from "@/lib/employee-portal/constants";
import {
  clearPortalSessionFlags,
  persistPortalSessionFlags,
} from "@/lib/employee-portal/sessionFlags";
import type { PortalPunchType } from "../utils/punchTypes";
import {
  buildWeekDisplayDays,
  monthDateBounds,
  navigateYearMonth,
} from "../utils/portalMonthlyUtils";

export type { PortalPunchType } from "../utils/punchTypes";

export interface PortalEmployee {
  id: string;
  tenant_id: string;
  full_name: string;
  pin_required: boolean;
  work_profile?: string;
  legacy_in_out_only?: boolean;
}

export interface PortalPublicPolicy {
  default_pin_required: boolean;
}

export interface PortalPunch {
  id: string;
  punch_type: string;
  occurred_at: string;
  received_at: string | null;
  anomaly_codes: string[] | null;
  source: string | null;
  pause_type: string | null;
  is_remote: boolean | null;
  pending?: boolean;
}

export interface PortalTodayResponse {
  employee_id: string;
  tenant_id: string;
  work_date: string;
  punches: PortalPunch[];
  last_punch_type: string | null;
  last_punch_at: string | null;
  current_status: "outside" | "on_day" | "working" | "on_pause" | "traveling" | "unknown";
  active_pause_type: string | null;
  open_pause_since: string | null;
  work_profile?: string | null;
  legacy_in_out_only?: boolean | null;
  day_state?: string | null;
  punch_only_at_stations?: boolean | null;
}

export interface PortalPauseConfig {
  id: string;
  key: string;
  label_i18n: Record<string, string> | null;
  counts_as_work: boolean;
  max_duration_minutes: number | null;
  sort_order: number;
}

export interface PortalAbsenceType {
  id: string;
  absence_type: string;
  name_i18n: Record<string, string> | null;
  counts_as_worked: boolean;
  requires_approval: boolean;
  requires_document: boolean;
  max_days_per_year: number | null;
  is_partial: boolean;
  sort_order: number;
}

export interface PortalAbsenceRow {
  id: string;
  absence_type: string;
  start_date: string;
  end_date: string;
  status: string;
  notes: string | null;
  partial_start_time: string | null;
  partial_end_time: string | null;
  created_at: string;
}

export interface PortalAccessLogRow {
  id: number;
  accessed_at: string;
  action: string;
  http_status: number | null;
  failure_reason: string | null;
  ip_address: string | null;
  metadata?: Record<string, unknown> | null;
}

export interface PortalPeriodConfirmationRow {
  id: string;
  period_from: string;
  period_to: string;
  cycle_type: string;
  calendar_year: number;
  calendar_month: number;
  confirmed_at: string;
  confirmed_via: string;
}

export interface PortalAccessLogsResponse {
  logs: PortalAccessLogRow[];
  period_confirmations: PortalPeriodConfirmationRow[];
}

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

export interface PortalScheduleResponse {
  employee_id: string;
  tenant_id: string;
  from: string;
  to: string;
  days: PortalScheduleDay[];
  absences: PortalScheduleAbsence[];
}

export interface PortalHistoryDay {
  id: string;
  work_date: string;
  starts_at: string | null;
  ends_at: string | null;
  net_minutes: number | null;
  status: string;
}

export interface PortalHistoryResponse {
  employee_id: string;
  tenant_id: string;
  from: string;
  to: string;
  days: PortalHistoryDay[];
  total_net_minutes: number;
}

export class PortalApiError extends Error {
  constructor(
    public readonly code: string,
    message?: string,
    public readonly retryAfterSeconds?: number,
  ) {
    super(message ?? code);
    this.name = "PortalApiError";
  }
}

async function parseApiError(response: Response): Promise<PortalApiError> {
  const body = await response.json().catch(() => ({}));
  const error = (body as {
    error?: { code?: string; message?: string; retry_after_seconds?: number };
  }).error;
  const code = error?.code ?? `HTTP_${response.status}`;
  return new PortalApiError(code, error?.message, error?.retry_after_seconds);
}

function storeEmployeeFlags(employee: PortalEmployee): void {
  persistPortalSessionFlags(employee);
}

export type PortalBootstrapState =
  | "token_invalid"
  | "identity_not_configured"
  | "requires_identity"
  | "pin_setup"
  | "pin"
  | "ready";

export interface PortalBootstrapStateResponse {
  state: PortalBootstrapState;
  full_name?: string;
  identity_locked?: boolean;
  retry_after_seconds?: number;
}

export async function fetchBootstrapState(secret: string): Promise<PortalBootstrapStateResponse> {
  const params = new URLSearchParams({ secret });
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/bootstrap/state?${params}`, {
    credentials: "include",
    cache: "no-store",
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export async function verifyPortalIdentity(
  secret: string,
  documentId: string,
): Promise<{ full_name: string }> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/identity/verify`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret, document_id: documentId }),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export async function confirmPortalIdentity(secret: string): Promise<{
  next: "pin_setup" | "pin" | "ready";
  full_name: string;
}> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/identity/confirm`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret }),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export async function rejectPortalIdentity(secret: string): Promise<void> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/identity/reject`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret }),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }
}

export async function createPortalSession(secret: string, pin?: string): Promise<{
  employee: PortalEmployee;
  expires_in: number;
}> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/session`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret, ...(pin ? { pin } : {}) }),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  const body = await response.json();
  const employee = body.employee as PortalEmployee;
  storeEmployeeFlags(employee);
  return { employee, expires_in: body.expires_in as number };
}

export async function validatePortalPinReset(secret: string): Promise<{
  valid: boolean;
  employee_name: string;
  expires_at: string;
}> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/pin/reset/validate`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret }),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export async function consumePortalPinReset(
  secret: string,
  pin: string,
  confirmPin: string,
): Promise<{ employee_name: string }> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/pin/reset/consume`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret, pin, confirm_pin: confirmPin }),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export async function fetchPortalMe(): Promise<PortalEmployee> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/session/me`, {
    credentials: "include",
    cache: "no-store",
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  const body = await response.json();
  const employee = body.employee as PortalEmployee;
  storeEmployeeFlags(employee);
  return employee;
}

export async function refreshPortalSession(pin?: string): Promise<PortalEmployee> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/session/refresh`, {
    method: "POST",
    credentials: "include",
    headers: pin ? { "Content-Type": "application/json" } : undefined,
    body: pin ? JSON.stringify({ pin }) : undefined,
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  const body = await response.json();
  const employee = body.employee as PortalEmployee;
  storeEmployeeFlags(employee);
  return employee;
}

export async function logoutPortalSession(): Promise<void> {
  await fetch(`${EMPLOYEE_PORTAL_API_BASE}/session/logout`, {
    method: "POST",
    credentials: "include",
  }).catch(() => undefined);
  clearPortalSessionFlags();
}

export async function setupPortalPin(
  secret: string,
  pin: string,
  confirmPin: string,
): Promise<{ employee: PortalEmployee; expires_in: number }> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/pin/setup`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret, pin, confirm_pin: confirmPin }),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  const body = await response.json();
  const employee = body.employee as PortalEmployee;
  storeEmployeeFlags(employee);
  return { employee, expires_in: body.expires_in as number };
}

export async function changePortalPin(
  currentPin: string,
  newPin: string,
  confirmPin: string,
): Promise<void> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/pin/change`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      current_pin: currentPin,
      new_pin: newPin,
      confirm_pin: confirmPin,
    }),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }
}

export async function fetchPortalToday(): Promise<PortalTodayResponse> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/today`, {
    credentials: "include",
    cache: "no-store",
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export interface PortalQrIdentityToken {
  token_id: string;
  token: string;
  method: string;
  expires_at: string;
  ttl_seconds: number;
}

export async function issuePortalQrIdentityToken(): Promise<PortalQrIdentityToken> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/identity/qr-token`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export async function fetchPortalSchedule(from: string, to: string): Promise<PortalScheduleResponse> {
  const params = new URLSearchParams({ from, to });
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/schedule?${params}`, {
    credentials: "include",
    cache: "no-store",
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export interface PortalMyShiftSlot {
  id: string;
  slot_date: string;
  start_time: string;
  end_time: string;
  spans_midnight: boolean;
  status: string;
  shift_id: string | null;
  shift_name: string;
  shift_color: string | null;
  site_id: string | null;
  location_id: string | null;
  location_name: string | null;
  location_path: string | null;
  publication_id: string | null;
  published_at: string | null;
  notes: string | null;
}

export interface PortalMyShiftsResponse {
  employee_id: string;
  tenant_id: string;
  from: string;
  to: string;
  slots: PortalMyShiftSlot[];
}

export async function fetchPortalMyShifts(from: string, to: string): Promise<PortalMyShiftsResponse> {
  const params = new URLSearchParams({ from, to });
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/shifts?${params}`, {
    credentials: "include",
    cache: "no-store",
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export interface PortalOpeningClaim {
  id: string;
  status: string;
  claimed_at: string;
  notes: string | null;
}

export interface PortalShiftOpening {
  id: string;
  opening_date: string;
  start_time: string;
  end_time: string;
  spans_midnight: boolean;
  places_total: number;
  places_filled: number;
  places_remaining: number;
  claim_policy: string;
  title: string | null;
  notes: string | null;
  compensation_label: string | null;
  role_name: string | null;
  location_name: string | null;
  closes_at: string | null;
  eligible: boolean;
  eligibility: { ok?: boolean; blocks?: string[]; warnings?: string[] };
  my_claim: PortalOpeningClaim | null;
}

export interface PortalShiftOpeningsResponse {
  employee_id: string;
  tenant_id: string;
  site_id: string;
  from: string;
  to: string;
  openings: PortalShiftOpening[];
}

export async function fetchPortalShiftOpenings(
  from: string,
  to: string,
): Promise<PortalShiftOpeningsResponse> {
  const params = new URLSearchParams({ from, to });
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/openings?${params}`, {
    credentials: "include",
    cache: "no-store",
  });
  if (!response.ok) throw await parseApiError(response);
  return response.json();
}

export async function claimPortalShiftOpening(input: {
  opening_id: string;
  notes?: string;
}): Promise<Record<string, unknown>> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/openings/claim`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!response.ok) throw await parseApiError(response);
  return response.json();
}

export async function withdrawPortalShiftOpeningClaim(input: {
  claim_id: string;
}): Promise<Record<string, unknown>> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/openings/withdraw`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!response.ok) throw await parseApiError(response);
  return response.json();
}

export interface PortalSwapRequest {
  id: string;
  kind: string;
  status: string;
  requester_slot_id: string;
  target_slot_id: string | null;
  target_employee_id: string | null;
  requester_notes: string | null;
  created_at: string;
  slot_date: string;
  start_time: string;
  end_time: string;
  is_mine: boolean;
  is_target: boolean;
}

export async function fetchPortalShiftSwaps(): Promise<{ requests: PortalSwapRequest[] }> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/swaps`, {
    credentials: "include",
    cache: "no-store",
  });
  if (!response.ok) throw await parseApiError(response);
  return response.json();
}

export async function requestPortalShiftSwap(input: {
  requester_slot_id: string;
  kind: "give_away" | "call_off";
  notes?: string;
  target_employee_id?: string;
}): Promise<Record<string, unknown>> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/swaps/request`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!response.ok) throw await parseApiError(response);
  return response.json();
}

export async function fetchPortalHistory(from: string, to: string): Promise<PortalHistoryResponse> {
  const params = new URLSearchParams({ from, to });
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/history?${params}`, {
    credentials: "include",
    cache: "no-store",
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export interface PortalMonthlyReportDay {
  work_date: string;
  starts_at: string | null;
  ends_at: string | null;
  break_minutes: number | null;
  net_minutes: number | null;
  status: string | null;
  anomaly_codes: string[];
}

export interface PortalMonthlyCloseIssue {
  code: string;
  count?: number;
  work_date?: string;
  work_dates?: string[];
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

export interface PortalMonthlyReportResponse {
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
  export: {
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
  };
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

export async function fetchPortalMonthlyReport(
  year: number,
  month: number,
  periodFrom?: string,
  periodTo?: string,
): Promise<PortalMonthlyReportResponse> {
  const params = new URLSearchParams({
    year: String(year),
    month: String(month),
  });
  if (periodFrom && periodTo) {
    params.set("period_from", periodFrom);
    params.set("period_to", periodTo);
  }
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/monthly-report?${params}`, {
    credentials: "include",
    cache: "no-store",
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export function createEmptyCalendarDay(workDate: string): PortalMonthlyCalendarDay {
  return {
    work_date: workDate,
    day_type: null,
    expected_minutes: 0,
    worked_minutes: 0,
    overtime_minutes: 0,
    balance_minutes: 0,
    is_laborable: false,
    holiday_name: null,
    starts_at: null,
    ends_at: null,
    net_minutes: null,
    break_minutes: null,
    absence_id: null,
    absence_type: null,
    absence_status: null,
    is_it: false,
    entry_status: null,
    summary_status: null,
    payroll_action: null,
  };
}

export async function fetchPortalWeekReport(
  legalYear: number,
  legalMonth: number,
  week: { from: string; to: string },
): Promise<PortalMonthlyReportResponse> {
  const bounds = monthDateBounds(legalYear, legalMonth);
  const monthKeys = new Set<string>();
  const fetches: Array<{ year: number; month: number }> = [{ year: legalYear, month: legalMonth }];

  if (week.from < bounds.from) {
    const prev = navigateYearMonth(legalYear, legalMonth, -1);
    const key = `${prev.year}-${prev.month}`;
    if (!monthKeys.has(key)) {
      monthKeys.add(key);
      fetches.push(prev);
    }
  }
  if (week.to > bounds.to) {
    const next = navigateYearMonth(legalYear, legalMonth, 1);
    const key = `${next.year}-${next.month}`;
    if (!monthKeys.has(key)) {
      monthKeys.add(key);
      fetches.push(next);
    }
  }

  monthKeys.add(`${legalYear}-${legalMonth}`);

  const reports = await Promise.all(
    fetches.map(({ year, month }) =>
      fetchPortalMonthlyReport(year, month, week.from, week.to),
    ),
  );

  const primary =
    reports.find((r) => r.year === legalYear && r.month === legalMonth) ?? reports[0];

  const dayMap = new Map<string, PortalMonthlyCalendarDay>();
  for (const report of reports) {
    for (const day of report.calendar_days) {
      dayMap.set(day.work_date, day);
    }
  }

  return {
    ...primary,
    calendar_days: buildWeekDisplayDays(week, [...dayMap.values()], createEmptyCalendarDay),
  };
}

export async function confirmPortalPeriodReport(input: {
  period_from: string;
  period_to: string;
  calendar_year: number;
  calendar_month: number;
}): Promise<{ confirmation_id: string }> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/monthly-report/confirm`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export async function confirmPortalMonthlyReport(
  year: number,
  month: number,
): Promise<{ report_id: string }> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/monthly-report/confirm`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ year, month }),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export interface PortalDocumentAssignment {
  id: string;
  assignment_kind: string;
  title: string;
  published_at: string;
  acknowledged_at: string | null;
  requires_signature: boolean;
  signature_submission_id: string | null;
  signature_completed: boolean;
  employee_sign_url: string | null;
  is_pending: boolean;
  document_version_id: string;
  mime_type: string | null;
  storage_path: string | null;
  view_url?: string | null;
}

export interface PortalDocumentsResponse {
  employee_id: string;
  documents: PortalDocumentAssignment[];
  settings: {
    requires_signature: boolean;
    required_before_punch: boolean;
  };
}

export interface PortalContentListItem {
  id: string;
  slug: string;
  title: string;
  excerpt: string | null;
  content_type: string;
  is_sticky: boolean;
  published_at: string | null;
}

export interface PortalContentListResponse {
  items: PortalContentListItem[];
}

export interface PortalContentDetail {
  id: string;
  slug: string;
  title: string;
  content_type: string;
  content: { html?: string } | null;
  published_at: string | null;
}

export async function fetchPortalContent(): Promise<PortalContentListResponse> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/content`, {
    credentials: "include",
    cache: "no-store",
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export async function fetchPortalContentBySlug(slug: string): Promise<PortalContentDetail> {
  const response = await fetch(
    `${EMPLOYEE_PORTAL_API_BASE}/content/${encodeURIComponent(slug)}`,
    {
      credentials: "include",
      cache: "no-store",
    },
  );

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export async function fetchPortalDocuments(): Promise<PortalDocumentsResponse> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/documents`, {
    credentials: "include",
    cache: "no-store",
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export async function acknowledgePortalDocument(
  assignmentId: string,
): Promise<{ acknowledged_at: string }> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/documents/acknowledge`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ assignment_id: assignmentId }),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export { generateClientOpId } from "./clientOpId";

export async function fetchPortalPauseConfigs(): Promise<PortalPauseConfig[]> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/pause-configs`, {
    credentials: "include",
    cache: "no-store",
  });
  if (!response.ok) throw await parseApiError(response);
  const body = await response.json();
  return (body.configs ?? []) as PortalPauseConfig[];
}

export async function fetchPortalAbsenceTypes(): Promise<PortalAbsenceType[]> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/absence-types`, {
    credentials: "include",
    cache: "no-store",
  });
  if (!response.ok) throw await parseApiError(response);
  const body = await response.json();
  return (body.types ?? []) as PortalAbsenceType[];
}

export async function fetchPortalAbsences(): Promise<PortalAbsenceRow[]> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/absences`, {
    credentials: "include",
    cache: "no-store",
  });
  if (!response.ok) throw await parseApiError(response);
  const body = await response.json();
  return (body.absences ?? []) as PortalAbsenceRow[];
}

export async function requestPortalAbsence(input: {
  absence_type: string;
  start_date: string;
  end_date: string;
  notes?: string;
  partial_start_time?: string;
  partial_end_time?: string;
}): Promise<{ absence_id: string; status: string }> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/absences/request`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!response.ok) throw await parseApiError(response);
  return response.json();
}

export async function fetchPortalAccessLogs(): Promise<PortalAccessLogsResponse> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/access-logs`, {
    credentials: "include",
    cache: "no-store",
  });
  if (!response.ok) throw await parseApiError(response);
  const body = (await response.json()) as Record<string, unknown>;
  const logsRaw = Array.isArray(body.logs) ? body.logs : [];
  const confirmationsRaw = Array.isArray(body.period_confirmations)
    ? body.period_confirmations
    : [];

  return {
    logs: logsRaw as PortalAccessLogRow[],
    period_confirmations: confirmationsRaw.map((row) => {
      const r = row as Record<string, unknown>;
      return {
        id: String(r.id ?? ""),
        period_from: String(r.period_from ?? ""),
        period_to: String(r.period_to ?? ""),
        cycle_type: String(r.cycle_type ?? ""),
        calendar_year: Number(r.calendar_year ?? 0),
        calendar_month: Number(r.calendar_month ?? 0),
        confirmed_at: String(r.confirmed_at ?? ""),
        confirmed_via: String(r.confirmed_via ?? ""),
      };
    }),
  };
}

export async function fetchPortalVapidPublicKey(): Promise<{ public_key: string | null; enabled: boolean }> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/push/vapid-public-key`, {
    credentials: "include",
    cache: "no-store",
  });
  if (!response.ok) throw await parseApiError(response);
  return response.json();
}

export async function subscribePortalPush(subscription: {
  endpoint: string;
  keys: { p256dh: string; auth: string };
}): Promise<{ saved: boolean }> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/push/subscribe`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(subscription),
  });
  if (!response.ok) throw await parseApiError(response);
  return response.json();
}

export async function recordPortalPunch(input: {
  client_op_id: string;
  punch_type: PortalPunchType;
  occurred_at?: string;
  device_info?: Record<string, string>;
  pause_type?: string;
  pause_counts_as_work?: boolean;
}): Promise<{ punch_id: string; status: string; anomaly_codes: string[] }> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/punch`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}

export async function syncPortalPunches(
  ops: Array<{
    client_op_id: string;
    punch_type: PortalPunchType | string;
    occurred_at: string;
    device_info?: Record<string, string> | null;
    pause_type?: string | null;
    pause_counts_as_work?: boolean | null;
  }>,
): Promise<{
  results: Array<{
    client_op_id: string;
    status: string;
    punch_id?: string | null;
    message?: string | null;
  }>;
}> {
  const response = await fetch(`${EMPLOYEE_PORTAL_API_BASE}/punch/sync`, {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ops }),
  });

  if (!response.ok) {
    throw await parseApiError(response);
  }

  return response.json();
}
