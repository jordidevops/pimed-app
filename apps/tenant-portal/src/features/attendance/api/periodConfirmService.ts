import { supabase } from '@/lib/supabase'

export type EmployeeConfirmCycle = 'calendar_month' | 'iso_week'

export interface PeriodConfirmation {
  id: string
  period_from: string
  period_to: string
  cycle_type: string
  calendar_year: number
  calendar_month: number
  confirmed_at: string
  confirmed_via: string
}

export interface MonthPeriodStatus {
  cycle: EmployeeConfirmCycle
  month_from: string
  month_to: string
  confirmations: PeriodConfirmation[]
  weeks_required: number
  weeks_confirmed: number
  month_period_confirmed: boolean
  month_fully_confirmed: boolean
}

export interface ListPeriodConfirmationsResult {
  confirmations: PeriodConfirmation[]
}

export function monthPeriodStatusQueryKey(
  employeeId: string,
  year: number,
  month: number,
): readonly ['attendance', 'month-period-status', string, number, number] {
  return ['attendance', 'month-period-status', employeeId, year, month]
}

export function monthPeriodStatusBatchQueryKey(
  employeeIds: string[],
  year: number,
  month: number,
): readonly ['attendance', 'month-period-status-batch', string, number, number] {
  const ids = [...employeeIds].sort().join(',')
  return ['attendance', 'month-period-status-batch', ids, year, month]
}

function mapPeriodConfirmation(raw: Record<string, unknown>): PeriodConfirmation {
  return {
    id: String(raw.id ?? ''),
    period_from: String(raw.period_from ?? ''),
    period_to: String(raw.period_to ?? ''),
    cycle_type: String(raw.cycle_type ?? ''),
    calendar_year: Number(raw.calendar_year ?? 0),
    calendar_month: Number(raw.calendar_month ?? 0),
    confirmed_at: String(raw.confirmed_at ?? ''),
    confirmed_via: String(raw.confirmed_via ?? ''),
  }
}

function mapMonthPeriodStatus(raw: Record<string, unknown>): MonthPeriodStatus {
  const cycleRaw = String(raw.cycle ?? 'calendar_month')
  const confirmationsRaw = Array.isArray(raw.confirmations) ? raw.confirmations : []

  return {
    cycle: cycleRaw === 'iso_week' ? 'iso_week' : 'calendar_month',
    month_from: String(raw.month_from ?? ''),
    month_to: String(raw.month_to ?? ''),
    confirmations: confirmationsRaw.map((row) =>
      mapPeriodConfirmation(row as Record<string, unknown>),
    ),
    weeks_required: Number(raw.weeks_required ?? 0),
    weeks_confirmed: Number(raw.weeks_confirmed ?? 0),
    month_period_confirmed: Boolean(raw.month_period_confirmed ?? false),
    month_fully_confirmed: Boolean(raw.month_fully_confirmed ?? false),
  }
}

export async function fetchMonthPeriodStatus(
  employeeId: string,
  year: number,
  month: number,
): Promise<MonthPeriodStatus> {
  const { data, error } = await supabase.rpc('get_attendance_month_period_status', {
    p_employee_id: employeeId,
    p_year: year,
    p_month: month,
  })

  if (error) throw new Error(error.message)
  return mapMonthPeriodStatus((data ?? {}) as Record<string, unknown>)
}

export async function fetchMonthPeriodStatusBatch(
  employeeIds: string[],
  year: number,
  month: number,
): Promise<Record<string, MonthPeriodStatus>> {
  if (employeeIds.length === 0) return {}

  const { data, error } = await supabase.rpc('get_attendance_month_period_status_batch', {
    p_employee_ids: employeeIds,
    p_year: year,
    p_month: month,
  })

  if (error) throw new Error(error.message)

  const payload = (data ?? {}) as Record<string, unknown>
  const rows = Array.isArray(payload.employees) ? payload.employees : []
  const result: Record<string, MonthPeriodStatus> = {}

  for (const row of rows) {
    const raw = row as Record<string, unknown>
    const employeeId = String(raw.employee_id ?? '')
    if (!employeeId) continue
    result[employeeId] = mapMonthPeriodStatus(raw)
  }

  return result
}

export async function listPeriodConfirmations(
  employeeId: string,
  year: number,
  month: number,
): Promise<ListPeriodConfirmationsResult> {
  const { data, error } = await supabase.rpc('list_attendance_period_confirmations', {
    p_employee_id: employeeId,
    p_year: year,
    p_month: month,
  })

  if (error) throw new Error(error.message)
  const payload = (data ?? {}) as Record<string, unknown>
  const rows = Array.isArray(payload.confirmations) ? payload.confirmations : []

  return {
    confirmations: rows.map((row) => mapPeriodConfirmation(row as Record<string, unknown>)),
  }
}

export async function confirmAttendancePeriod(
  employeeId: string,
  periodFrom: string,
  periodTo: string,
  calendarYear?: number,
  calendarMonth?: number,
): Promise<string> {
  const { data, error } = await supabase.rpc('confirm_attendance_period', {
    p_employee_id: employeeId,
    p_period_from: periodFrom,
    p_period_to: periodTo,
    p_confirmed_via: 'tenant_app',
    p_calendar_year: calendarYear ?? null,
    p_calendar_month: calendarMonth ?? null,
    p_source_session_id: null,
  })

  if (error) throw new Error(error.message)
  return String(data)
}
