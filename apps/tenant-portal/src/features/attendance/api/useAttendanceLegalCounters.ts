import { useQuery } from '@tanstack/react-query'
import { fetchAttendanceLegalCounters } from './legalCountersService'

export function useAttendanceLegalCounters(
  employeeId: string | null | undefined,
  asOfDate?: string,
  enabled = true,
) {
  return useQuery({
    queryKey: ['attendance', 'legal-counters', employeeId, asOfDate ?? 'today'],
    queryFn: () => fetchAttendanceLegalCounters(employeeId!, asOfDate),
    enabled: !!employeeId && enabled,
    staleTime: 60_000,
  })
}
