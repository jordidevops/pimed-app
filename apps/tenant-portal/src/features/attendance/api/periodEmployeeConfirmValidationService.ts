import { supabase } from '@/lib/supabase'
import type { MonthlyCloseIssue } from './monthlyCloseValidationService'

export interface PeriodEmployeeConfirmValidation {
  confirmable: boolean
  blockers: MonthlyCloseIssue[]
  period?: { from: string; to: string }
}

export function periodEmployeeConfirmValidationQueryKey(
  employeeId: string,
  periodFrom: string,
  periodTo: string,
) {
  return [
    'attendance',
    'period-employee-confirm-validation',
    employeeId,
    periodFrom,
    periodTo,
  ] as const
}

export async function validateAttendancePeriodEmployeeConfirm(
  employeeId: string,
  periodFrom: string,
  periodTo: string,
): Promise<PeriodEmployeeConfirmValidation> {
  const { data, error } = await supabase.rpc(
    'validate_attendance_period_employee_confirm' as never,
    {
      p_employee_id: employeeId,
      p_period_from: periodFrom,
      p_period_to: periodTo,
    } as never,
  )

  if (error) throw new Error(error.message)
  return data as unknown as PeriodEmployeeConfirmValidation
}
