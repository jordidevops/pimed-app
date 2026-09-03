import { useQuery } from '@tanstack/react-query'
import {
  monthlyEmployeeConfirmValidationQueryKey,
  validateAttendanceMonthEmployeeConfirm,
} from './monthlyEmployeeConfirmValidationService'

export function useMonthlyEmployeeConfirmValidation(
  employeeId: string | null | undefined,
  year: number,
  month: number,
  enabled = true,
) {
  return useQuery({
    queryKey: monthlyEmployeeConfirmValidationQueryKey(employeeId ?? '', year, month),
    queryFn: () => validateAttendanceMonthEmployeeConfirm(employeeId!, year, month),
    enabled: enabled && !!employeeId && year > 0 && month >= 1 && month <= 12,
    staleTime: 15_000,
  })
}
