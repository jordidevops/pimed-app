import { useQuery } from '@tanstack/react-query'
import {
  fetchMonthPeriodStatusBatch,
  monthPeriodStatusBatchQueryKey,
  type MonthPeriodStatus,
} from './periodConfirmService'

export function useMonthPeriodStatusBatch(
  employeeIds: string[],
  year: number,
  month: number,
  enabled = true,
) {
  const sortedIds = [...employeeIds].sort()

  return useQuery({
    queryKey: monthPeriodStatusBatchQueryKey(sortedIds, year, month),
    queryFn: () => fetchMonthPeriodStatusBatch(sortedIds, year, month),
    enabled: enabled && sortedIds.length > 0,
    staleTime: 30_000,
  })
}

export type MonthPeriodStatusMap = Record<string, MonthPeriodStatus>
