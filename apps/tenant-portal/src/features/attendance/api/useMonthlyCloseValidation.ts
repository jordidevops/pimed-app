import { useQuery } from '@tanstack/react-query'
import {
  monthlyCloseValidationQueryKey,
  validateAttendanceMonthClose,
} from './monthlyCloseValidationService'

export function useMonthlyCloseValidation(
  employeeId: string | null | undefined,
  year: number,
  month: number,
  enabled = true,
) {
  return useQuery({
    queryKey: monthlyCloseValidationQueryKey(employeeId ?? '', year, month),
    queryFn: () => validateAttendanceMonthClose(employeeId!, year, month),
    enabled: enabled && !!employeeId && year > 0 && month >= 1 && month <= 12,
    staleTime: 15_000,
  })
}
