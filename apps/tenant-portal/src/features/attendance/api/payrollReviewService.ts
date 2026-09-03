import { supabase } from '@/lib/supabase'

export type PayrollReviewAction = 'approve' | 'absence_ok' | 'missing_punch' | 'blocked' | null

export interface PayrollReviewDay {
  work_date: string
  day_type: string
  expected_minutes: number
  holiday_name: string | null
  is_laborable: boolean
  worked_minutes: number
  effective_minutes?: number | null
  paid_minutes?: number | null
  work_profile_snapshot?: string | null
  overtime_minutes: number
  punch_count: number
  remote_punch_count: number
  entry_status: string | null
  summary_status: string
  needs_review: boolean
  anomalies: string[]
  summary_id: string | null
  absence_id: string | null
  absence_type: string | null
  absence_status: string | null
  absence_is_paid: boolean | null
  partial_start_time: string | null
  partial_end_time: string | null
  partial_hours: number | null
  is_it: boolean
  it_type: string | null
  absence_export_code: string | null
  absence_parent_key: string | null
  absence_subtype_key: string | null
  payroll_locked: boolean
  payroll_action: PayrollReviewAction
}

export interface PayrollReviewDaysResult {
  employee_id: string
  from: string
  to: string
  days: PayrollReviewDay[]
}

export function payrollReviewDaysQueryKey(employeeId: string, from: string, to: string) {
  return ['attendance', 'payroll-review-days', employeeId, from, to] as const
}

function mapDay(raw: Record<string, unknown>): PayrollReviewDay {
  const anomalies = raw.anomalies
  return {
    work_date: String(raw.work_date).slice(0, 10),
    day_type: String(raw.day_type ?? 'unknown'),
    expected_minutes: Number(raw.expected_minutes ?? 0),
    holiday_name: (raw.holiday_name as string | null) ?? null,
    is_laborable: Boolean(raw.is_laborable),
    worked_minutes: Number(raw.worked_minutes ?? 0),
    effective_minutes:
      raw.effective_minutes == null ? null : Number(raw.effective_minutes),
    paid_minutes: raw.paid_minutes == null ? null : Number(raw.paid_minutes),
    work_profile_snapshot: (raw.work_profile_snapshot as string | null) ?? null,
    overtime_minutes: Number(raw.overtime_minutes ?? 0),
    punch_count: Number(raw.punch_count ?? 0),
    remote_punch_count: Number(raw.remote_punch_count ?? 0),
    entry_status: (raw.entry_status as string | null) ?? null,
    summary_status: String(raw.summary_status ?? 'none'),
    needs_review: Boolean(raw.needs_review),
    anomalies: Array.isArray(anomalies) ? anomalies.map(String) : [],
    summary_id: (raw.summary_id as string | null) ?? null,
    absence_id: (raw.absence_id as string | null) ?? null,
    absence_type: (raw.absence_type as string | null) ?? null,
    absence_status: (raw.absence_status as string | null) ?? null,
    absence_is_paid: raw.absence_is_paid == null ? null : Boolean(raw.absence_is_paid),
    partial_start_time: (raw.partial_start_time as string | null) ?? null,
    partial_end_time: (raw.partial_end_time as string | null) ?? null,
    partial_hours: raw.partial_hours == null ? null : Number(raw.partial_hours),
    is_it: Boolean(raw.is_it),
    it_type: (raw.it_type as string | null) ?? null,
    absence_export_code: (raw.absence_export_code as string | null) ?? null,
    absence_parent_key: (raw.absence_parent_key as string | null) ?? null,
    absence_subtype_key: (raw.absence_subtype_key as string | null) ?? null,
    payroll_locked: Boolean(raw.payroll_locked),
    payroll_action: (raw.payroll_action as PayrollReviewAction) ?? null,
  }
}

export async function fetchPayrollReviewDays(
  employeeId: string,
  from: string,
  to: string,
): Promise<PayrollReviewDaysResult> {
  const { data, error } = await supabase.rpc('get_payroll_review_days' as never, {
    p_employee_id: employeeId,
    p_from: from,
    p_to: to,
  } as never)

  if (error) throw new Error(error.message)

  const payload = data as Record<string, unknown>
  const daysRaw = Array.isArray(payload.days) ? payload.days : []

  return {
    employee_id: String(payload.employee_id ?? employeeId),
    from: String(payload.from ?? from),
    to: String(payload.to ?? to),
    days: daysRaw.map((d) => mapDay(d as Record<string, unknown>)),
  }
}
