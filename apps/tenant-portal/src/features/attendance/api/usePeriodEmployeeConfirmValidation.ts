import { useQuery } from '@tanstack/react-query'
import {
  periodEmployeeConfirmValidationQueryKey,
  validateAttendancePeriodEmployeeConfirm,
} from './periodEmployeeConfirmValidationService'

export function usePeriodEmployeeConfirmValidation(
  employeeId: string | null | undefined,
  periodFrom: string | null | undefined,
  periodTo: string | null | undefined,
  enabled = true,
) {
  return useQuery({
    queryKey: periodEmployeeConfirmValidationQueryKey(
      employeeId ?? '',
      periodFrom ?? '',
      periodTo ?? '',
    ),
    queryFn: () =>
      validateAttendancePeriodEmployeeConfirm(employeeId!, periodFrom!, periodTo!),
    enabled: !!employeeId && !!periodFrom && !!periodTo && enabled,
    staleTime: 30_000,
  })
}
