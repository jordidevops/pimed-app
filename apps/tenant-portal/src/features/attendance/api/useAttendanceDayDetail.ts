import { useQuery } from '@tanstack/react-query'
import { fetchAttendanceDayDetail } from './dayDetailService'

export function useAttendanceDayDetail(
  employeeId: string | null,
  workDate: string | null,
  enabled = true,
) {
  return useQuery({
    queryKey: ['attendance', 'day-detail', employeeId, workDate],
    queryFn: () => fetchAttendanceDayDetail(employeeId!, workDate!),
    enabled: enabled && !!employeeId && !!workDate,
    staleTime: 0,
  })
}
