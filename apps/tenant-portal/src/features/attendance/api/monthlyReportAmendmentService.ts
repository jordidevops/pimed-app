import { supabase } from '@/lib/supabase'

export interface MonthlyReportAmendment {
  id: string
  report_id: string
  year: number
  month: number
  work_date: string | null
  reason: string
  description: string | null
  created_at: string
  created_by_name: string | null
}

export interface MonthlyReportAmendmentsResult {
  employee_id: string
  year: number
  month: number
  amendments: MonthlyReportAmendment[]
}

export interface RegisterMonthlyAmendmentInput {
  employeeId: string
  year: number
  month: number
  reason: string
  workDate?: string | null
  description?: string | null
}

export function monthlyReportAmendmentsQueryKey(
  employeeId: string,
  year: number,
  month: number,
) {
  return ['attendance', 'monthly-amendments', employeeId, year, month] as const
}

export async function fetchMonthlyReportAmendments(
  employeeId: string,
  year: number,
  month: number,
): Promise<MonthlyReportAmendmentsResult> {
  const { data, error } = await supabase.rpc('list_attendance_month_amendments' as never, {
    p_employee_id: employeeId,
    p_year: year,
    p_month: month,
  } as never)

  if (error) throw error
  const raw = data as {
    employee_id: string
    year: number
    month: number
    amendments: MonthlyReportAmendment[]
  }
  return {
    employee_id: raw.employee_id,
    year: raw.year,
    month: raw.month,
    amendments: raw.amendments ?? [],
  }
}

export async function registerMonthlyReportAmendment(
  input: RegisterMonthlyAmendmentInput,
): Promise<string> {
  const { data, error } = await supabase.rpc('register_attendance_month_amendment' as never, {
    p_employee_id: input.employeeId,
    p_year: input.year,
    p_month: input.month,
    p_reason: input.reason,
    p_work_date: input.workDate ?? null,
    p_description: input.description ?? null,
  } as never)

  if (error) throw error
  return String(data)
}
