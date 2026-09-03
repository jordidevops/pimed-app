import { useQuery } from '@tanstack/react-query'
import {
  summarizeLocationWork,
  type SummarizeLocationWorkParams,
} from './locationWorkSummaryService'

export function locationWorkSummaryQueryKey(params: SummarizeLocationWorkParams) {
  return [
    'attendance',
    'location-work-summary',
    params.siteId,
    params.from,
    params.to,
    params.employeeId ?? 'all',
    params.locationId ?? 'all',
  ] as const
}

export function useLocationWorkSummary(
  params: SummarizeLocationWorkParams | null,
  enabled = true,
) {
  return useQuery({
    queryKey: params
      ? locationWorkSummaryQueryKey(params)
      : (['attendance', 'location-work-summary', 'disabled'] as const),
    queryFn: () => summarizeLocationWork(params!),
    enabled: enabled && params != null,
    staleTime: 30_000,
  })
}
