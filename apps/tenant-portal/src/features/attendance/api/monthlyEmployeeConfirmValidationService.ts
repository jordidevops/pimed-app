import { supabase } from '@/lib/supabase'
import type { MonthlyCloseIssue } from './monthlyCloseValidationService'

export interface MonthlyEmployeeConfirmValidation {
  confirmable: boolean
  blockers: MonthlyCloseIssue[]
  period?: { from: string; to: string }
}

export function monthlyEmployeeConfirmValidationQueryKey(
  employeeId: string,
  year: number,
  month: number,
) {
  return ['attendance', 'monthly-employee-confirm-validation', employeeId, year, month] as const
}

export async function validateAttendanceMonthEmployeeConfirm(
  employeeId: string,
  year: number,
  month: number,
): Promise<MonthlyEmployeeConfirmValidation> {
  const { data, error } = await supabase.rpc(
    'validate_attendance_month_employee_confirm' as never,
    {
      p_employee_id: employeeId,
      p_year: year,
      p_month: month,
    } as never,
  )

  if (error) throw new Error(error.message)
  return data as unknown as MonthlyEmployeeConfirmValidation
}
