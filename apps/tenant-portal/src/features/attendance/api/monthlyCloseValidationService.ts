import { supabase } from '@/lib/supabase'

export type MonthlyCloseIssueCode =
  | 'FUTURE_MONTH'
  | 'CURRENT_MONTH_INCOMPLETE'
  | 'PERIOD_NOT_ENDED'
  | 'OPEN_TIME_ENTRY'
  | 'NEEDS_REVIEW'
  | 'MISSING_WORKDAY_RECORD'
  | 'DRAFT_DAYS'
  | 'ANOMALY_DAYS'
  | 'WORKED_EXPECTED_DIFF'
  | 'EMPLOYEE_PERIOD_CONFIRM_INCOMPLETE'
  | 'EMPLOYEE_CONFIRM_VIA_SIGNATURE'

export interface MonthlyCloseIssue {
  code: MonthlyCloseIssueCode
  count?: number
  work_dates?: string[]
  work_date?: string
  period_from?: string
  period_to?: string
  year?: number
  month?: number
  worked_minutes?: number
  expected_minutes?: number
  difference_minutes?: number
  threshold_minutes?: number
  cycle?: string
  weeks_confirmed?: number
  weeks_required?: number
  month_fully_confirmed?: boolean
}

export interface MonthlyCloseValidation {
  closable: boolean
  blockers: MonthlyCloseIssue[]
  warnings: MonthlyCloseIssue[]
  period?: { from: string; to: string }
  summary?: {
    open_entries: number
    needs_review_days: number
    missing_workdays: number
    draft_days: number
    anomaly_days: number
    worked_minutes: number
    expected_minutes: number
  }
}

export function monthlyCloseValidationQueryKey(
  employeeId: string,
  year: number,
  month: number,
) {
  return ['attendance', 'monthly-close-validation', employeeId, year, month] as const
}

export async function validateAttendanceMonthClose(
  employeeId: string,
  year: number,
  month: number,
): Promise<MonthlyCloseValidation> {
  const { data, error } = await supabase.rpc(
    'validate_attendance_month_close' as never,
    {
      p_employee_id: employeeId,
      p_year: year,
      p_month: month,
    } as never,
  )

  if (error) throw new Error(error.message)
  return data as unknown as MonthlyCloseValidation
}
