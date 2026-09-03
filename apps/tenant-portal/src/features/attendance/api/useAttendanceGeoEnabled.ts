import { useQuery } from '@tanstack/react-query'
import { attendanceKeys } from './attendanceKeys'
import { fetchAttendanceGeoEnabled } from './attendanceGeoService'

export function useAttendanceGeoEnabled(employeeId: string | null | undefined) {
  return useQuery({
    queryKey: attendanceKeys.geoEnabled(employeeId ?? ''),
    queryFn: () => fetchAttendanceGeoEnabled(employeeId!),
    enabled: !!employeeId,
    staleTime: 5 * 60_000,
  })
}
