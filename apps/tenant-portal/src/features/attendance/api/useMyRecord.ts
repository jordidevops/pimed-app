import { useQuery } from '@tanstack/react-query'
import { attendanceKeys } from './attendanceKeys'
import { getMyPunches, getMyEntries } from './attendanceService'
import type { TimePunch, TimeEntry } from './attendanceService'

export function useMyPunches(employeeId: string | null | undefined, from: string, to: string) {
  return useQuery<TimePunch[]>({
    queryKey: attendanceKeys.myPunches(employeeId ?? '', from, to),
    queryFn: () => getMyPunches(employeeId!, from, to),
    enabled: !!employeeId && !!from && !!to,
    staleTime: 2 * 60 * 1000,
  })
}

export function useMyEntries(employeeId: string | null | undefined, from: string, to: string) {
  return useQuery<TimeEntry[]>({
    queryKey: attendanceKeys.myEntries(employeeId ?? '', from, to),
    queryFn: () => getMyEntries(employeeId!, from, to),
    enabled: !!employeeId && !!from && !!to,
    staleTime: 2 * 60 * 1000,
  })
}
