import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'
import type { PayrollReviewAction } from './payrollReviewService'
import { fetchPayrollReviewDays, type PayrollReviewDay } from './payrollReviewService'
import {
  eachDateInRange,
  fetchSchedulePlannerActuals,
  type PlannerActualRecord,
} from './schedulePlannerService'

export type TimeDailySummary = Database['api']['Views']['time_daily_summaries']['Row']

export type TimesheetDaySource = 'summary' | 'punch' | 'empty'

export interface TimesheetDayRow {
  work_date: string
  worked_minutes: number
  expected_minutes: number | null
  punch_count: number
  status: string | null
  entry_status?: string | null
  summary_status?: string | null
  needs_review: boolean
  overtime_minutes?: number
  anomaly_codes: string[] | null
  source: TimesheetDaySource
  day_type?: string | null
  is_laborable?: boolean
  holiday_name?: string | null
  absence_id?: string | null
  absence_type?: string | null
  absence_status?: string | null
  is_it?: boolean
  payroll_action?: PayrollReviewAction
  partial_start_time?: string | null
  partial_end_time?: string | null
}

export async function getAllTimeDailySummaries(
  siteId: string,
  from: string,
  to: string,
  employeeId?: string,
): Promise<TimeDailySummary[]> {
  let q = supabase
    .from('time_daily_summaries')
    .select('*')
    .eq('site_id', siteId)
    .gte('work_date', from)
    .lte('work_date', to)
    .order('work_date', { ascending: false })
  if (employeeId) q = q.eq('employee_id', employeeId)
  const { data, error } = await q
  if (error) throw error
  return data ?? []
}

function mapSummaryRow(row: TimeDailySummary): TimesheetDayRow {
  const workDate = String(row.work_date).slice(0, 10)
  return {
    work_date: workDate,
    worked_minutes: row.worked_minutes ?? 0,
    expected_minutes: row.expected_minutes ?? null,
    punch_count: row.punch_count ?? 0,
    status: row.status ?? null,
    needs_review: row.needs_review ?? false,
    anomaly_codes: row.anomaly_codes ?? null,
    source: 'summary',
  }
}

function mapActualRow(row: PlannerActualRecord): TimesheetDayRow {
  return {
    work_date: row.work_date,
    worked_minutes: row.worked_minutes,
    expected_minutes: null,
    punch_count: row.punch_count,
    status: row.status,
    needs_review: row.needs_review,
    anomaly_codes: row.anomaly_codes,
    source: 'punch',
  }
}

function emptyDay(date: string): TimesheetDayRow {
  return {
    work_date: date,
    worked_minutes: 0,
    expected_minutes: null,
    punch_count: 0,
    status: null,
    needs_review: false,
    anomaly_codes: null,
    source: 'empty',
  }
}

function mapPayrollReviewToTimesheetDay(day: PayrollReviewDay): TimesheetDayRow {
  const hasSummary = day.summary_status !== 'none'
  const hasActivity = day.punch_count > 0 || day.worked_minutes > 0
  const payrollAction =
    day.payroll_action === 'missing_punch' && hasActivity
      ? (day.entry_status === 'open' ? 'blocked' : null)
      : day.payroll_action

  return {
    work_date: day.work_date,
    worked_minutes: day.worked_minutes,
    expected_minutes: day.expected_minutes > 0 ? day.expected_minutes : null,
    punch_count: day.punch_count,
    status: hasSummary ? day.summary_status : day.entry_status,
    entry_status: day.entry_status,
    summary_status: hasSummary ? day.summary_status : null,
    needs_review: day.needs_review,
    anomaly_codes: day.anomalies.length > 0 ? day.anomalies : null,
    source: hasActivity ? 'summary' : 'empty',
    day_type: day.day_type,
    is_laborable: day.is_laborable,
    holiday_name: day.holiday_name,
    absence_id: day.absence_id,
    absence_type: day.absence_type,
    absence_status: day.absence_status,
    is_it: day.is_it,
    payroll_action: payrollAction,
    partial_start_time: day.partial_start_time,
    partial_end_time: day.partial_end_time,
    overtime_minutes: day.overtime_minutes,
  }
}

export function employeeTimesheetQueryKey(employeeId: string, from: string, to: string) {
  return ['attendance', 'employee-timesheet', employeeId, from, to] as const
}

function enrichTimesheetDayFromActuals(
  day: TimesheetDayRow,
  actual?: PlannerActualRecord,
): TimesheetDayRow {
  if (!actual) return day

  // No sobreescriure hores processades (ajust/tancat) amb estimacions en viu del planner.
  if (day.entry_status === 'adjusted' || day.entry_status === 'closed') {
    return day
  }

  const workedMinutes = day.worked_minutes > 0 ? day.worked_minutes : actual.worked_minutes
  const punchCount = Math.max(day.punch_count, actual.punch_count)
  if (workedMinutes === day.worked_minutes && punchCount === day.punch_count) return day

  return {
    ...day,
    worked_minutes: workedMinutes,
    punch_count: punchCount,
    status: day.status ?? actual.status,
    needs_review: day.needs_review || actual.needs_review,
    anomaly_codes: day.anomaly_codes ?? actual.anomaly_codes,
    source: day.worked_minutes > 0 ? day.source : 'punch',
    payroll_action:
      day.payroll_action === 'missing_punch' && punchCount > 0
        ? (actual.status === 'open' || day.entry_status === 'open' ? 'blocked' : null)
        : day.payroll_action,
  }
}

/** Merged timesheet days via B2 payroll review RPC (calendar, absències, IT, faltes). */
export async function fetchEmployeeTimesheetDays(
  siteId: string,
  employeeId: string,
  from: string,
  to: string,
): Promise<TimesheetDayRow[]> {
  const [result, actuals] = await Promise.all([
    fetchPayrollReviewDays(employeeId, from, to),
    fetchSchedulePlannerActuals(siteId, from, to, [employeeId]),
  ])

  const actualsByDate = new Map(actuals.map((row) => [row.work_date, row]))

  return result.days.map((day) =>
    enrichTimesheetDayFromActuals(
      mapPayrollReviewToTimesheetDay(day),
      actualsByDate.get(day.work_date),
    ),
  )
}
/** Legacy merge (summaries + punch fallback) — kept for tests or fallback. */
export async function fetchEmployeeTimesheetDaysLegacy(
  siteId: string,
  employeeId: string,
  from: string,
  to: string,
): Promise<TimesheetDayRow[]> {
  const [summaries, actuals] = await Promise.all([
    getAllTimeDailySummaries(siteId, from, to, employeeId),
    fetchSchedulePlannerActuals(siteId, from, to, [employeeId]),
  ])

  const byDate = new Map<string, TimesheetDayRow>()
  for (const row of summaries) {
    byDate.set(String(row.work_date).slice(0, 10), mapSummaryRow(row))
  }
  for (const row of actuals) {
    if (!byDate.has(row.work_date) && row.punch_count > 0) {
      byDate.set(row.work_date, mapActualRow(row))
    }
  }

  return eachDateInRange(from, to).map((date) => byDate.get(date) ?? emptyDay(date))
}

export function formatTimesheetMinutes(min: number | null | undefined): string {
  if (min == null) return '—'
  const h = Math.floor(Math.abs(min) / 60)
  const m = Math.abs(min) % 60
  const sign = min < 0 ? '-' : ''
  return `${sign}${h}h ${String(m).padStart(2, '0')}m`
}

export const TIMESHEET_STATUS_CLASS: Record<string, string> = {
  open: 'bg-amber-100 text-amber-800',
  closed: 'bg-slate-100 text-slate-700',
  adjusted: 'bg-violet-100 text-violet-800',
  approved: 'bg-emerald-100 text-emerald-800',
  exported: 'bg-blue-100 text-blue-800',
  missing: 'bg-muted text-muted-foreground',
  draft: 'bg-amber-100 text-amber-800',
}

/** Capa A — jornada (`time_entries.status`) */
export const ENTRY_STATUSES = new Set(['open', 'closed', 'adjusted', 'missing'])

/** Capa B — dia nòmina (`time_daily_summaries.status`) */
export const SUMMARY_STATUSES = new Set(['draft', 'approved', 'exported'])

export type AttendanceStatusLayer = 'entry' | 'summary'

export function resolveAttendanceStatusLayer(status: string | null | undefined): AttendanceStatusLayer {
  if (status && SUMMARY_STATUSES.has(status)) return 'summary'
  return 'entry'
}

/** Clau i18n: `status_layers.entry.open`, `status_layers.summary.draft`, etc. */
export function attendanceStatusLabelKey(
  status: string | null | undefined,
  layer?: AttendanceStatusLayer,
): string | null {
  if (!status) return null
  const resolved = layer ?? resolveAttendanceStatusLayer(status)
  return `status_layers.${resolved}.${status}`
}

export function monthDateRange(year: number, month: number): { from: string; to: string } {
  const mm = String(month).padStart(2, '0')
  const from = `${year}-${mm}-01`
  const lastDay = new Date(year, month, 0).getDate()
  const to = `${year}-${mm}-${String(lastDay).padStart(2, '0')}`
  return { from, to }
}

/** Deep link B1: Fitxatges de l'equip amb empleat, local i rang del mes. */
export function payrollRecordsReviewUrl(
  employeeId: string,
  year: number,
  month: number,
  siteId?: string | null,
): string {
  const { from, to } = monthDateRange(year, month)
  const params = new URLSearchParams({ employeeId, from, to })
  if (siteId) params.set('siteId', siteId)
  return `/attendance-mgmt/records?${params.toString()}`
}

/** Deep link: revisió d'un dia concret a Fitxatges de l'equip. */
export function payrollRecordsDayReviewUrl(
  employeeId: string,
  workDate: string,
  siteId?: string | null,
): string {
  const params = new URLSearchParams({ employeeId, from: workDate, to: workDate })
  if (siteId) params.set('siteId', siteId)
  return `/attendance-mgmt/records?${params.toString()}`
}

/** Deep link: absències filtrades per empleat. */
export function employeeAbsencesUrl(employeeId: string): string {
  return `/attendance-mgmt/absences?${new URLSearchParams({ employeeId }).toString()}`
}
