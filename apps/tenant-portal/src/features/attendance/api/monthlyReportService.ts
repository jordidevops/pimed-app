import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type MonthlyReportRow = Database['api']['Views']['attendance_monthly_reports']['Row']

export type MonthlyReportStatus =
  | 'draft'
  | 'employee_confirmed'
  | 'manager_approved'
  | 'signed'
  | 'archived'
  | null

export interface MonthlyReportDaySegment {
  activity_kind: string
  started_at: string
  ended_at: string | null
}

export interface MonthlyReportDay {
  work_date: string
  starts_at: string | null
  ends_at: string | null
  break_minutes: number | null
  net_minutes: number | null
  status: string | null
  anomaly_codes: string[]
  presence_minutes?: number | null
  work_minutes?: number | null
  travel_minutes?: number | null
  effective_minutes?: number | null
  paid_minutes?: number | null
  overtime_minutes?: number | null
  overtime_authorized_minutes?: number | null
  work_profile?: string | null
  segment_breakdown?: MonthlyReportDaySegment[]
}

export interface MonthlyReportSummary {
  worked_minutes: number
  expected_minutes: number
  difference_minutes: number
  presence_minutes?: number | null
  effective_minutes?: number | null
  paid_minutes?: number | null
  travel_minutes?: number | null
  overtime_minutes?: number | null
  overtime_authorized_minutes?: number | null
  has_effective_time?: boolean
}

export interface MonthlyReportExport {
  employee_id: string
  employee_name: string
  year: number
  month: number
  days: MonthlyReportDay[]
  summary: MonthlyReportSummary
  generated_at: string
}

export async function fetchMonthlyReportStatus(
  employeeId: string,
  year: number,
  month: number,
): Promise<MonthlyReportRow | null> {
  const { data, error } = await supabase
    .from('attendance_monthly_reports')
    .select('*')
    .eq('employee_id', employeeId)
    .eq('year', year)
    .eq('month', month)
    .maybeSingle()

  if (error) throw new Error(error.message)
  return data
}

export async function exportAttendanceMonth(
  employeeId: string,
  year: number,
  month: number,
): Promise<MonthlyReportExport> {
  const { data, error } = await supabase.rpc('export_attendance_month', {
    p_employee_id: employeeId,
    p_year: year,
    p_month: month,
  })

  if (error) throw new Error(error.message)
  return data as unknown as MonthlyReportExport
}

export async function confirmAttendanceMonth(
  employeeId: string,
  year: number,
  month: number,
): Promise<string> {
  const { data, error } = await supabase.rpc('confirm_attendance_month', {
    p_employee_id: employeeId,
    p_year: year,
    p_month: month,
  })

  if (error) throw new Error(error.message)
  return String(data)
}

/** @deprecated A3 — use approve_attendance_month via useApproveAttendanceMonth */
export async function managerConfirmAttendanceMonth(
  employeeId: string,
  year: number,
  month: number,
): Promise<string> {
  const { data, error } = await supabase.rpc('manager_confirm_attendance_month', {
    p_employee_id: employeeId,
    p_year: year,
    p_month: month,
  })

  if (error) throw new Error(error.message)
  return String(data)
}

export async function approveAttendanceMonth(
  employeeId: string,
  year: number,
  month: number,
): Promise<string> {
  const { data, error } = await supabase.rpc('approve_attendance_month', {
    p_employee_id: employeeId,
    p_year: year,
    p_month: month,
  })

  if (error) throw new Error(error.message)
  return String(data)
}

export function monthLabel(year: number, month: number, locale = 'ca-ES'): string {
  return new Date(year, month - 1, 1).toLocaleDateString(locale, {
    month: 'long',
    year: 'numeric',
  })
}

export function downloadMonthlyReportJson(exportData: MonthlyReportExport): void {
  const filename = `registre-jornada_${exportData.employee_name.replace(/\s+/g, '-')}_${exportData.year}-${String(exportData.month).padStart(2, '0')}.json`
  const blob = new Blob([JSON.stringify(exportData, null, 2)], {
    type: 'application/json;charset=utf-8',
  })
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.click()
  URL.revokeObjectURL(url)
}

export function parseYearMonthFromDate(isoDate: string): { year: number; month: number } {
  const [y, m] = isoDate.split('-').map(Number)
  return { year: y, month: m }
}

export function currentYearMonth(): { year: number; month: number } {
  const d = new Date()
  return { year: d.getFullYear(), month: d.getMonth() + 1 }
}
