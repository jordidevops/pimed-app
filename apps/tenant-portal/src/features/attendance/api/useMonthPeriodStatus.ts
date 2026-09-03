import { useQuery } from '@tanstack/react-query'
import {
  fetchMonthPeriodStatus,
  monthPeriodStatusQueryKey,
} from './periodConfirmService'

export function useMonthPeriodStatus(
  employeeId: string | null | undefined,
  year: number,
  month: number,
  enabled = true,
) {
  return useQuery({
    queryKey: monthPeriodStatusQueryKey(employeeId ?? '', year, month),
    queryFn: () => fetchMonthPeriodStatus(employeeId!, year, month),
    enabled: !!employeeId && enabled,
    staleTime: 30_000,
  })
}
