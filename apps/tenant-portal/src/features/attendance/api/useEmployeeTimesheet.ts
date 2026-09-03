import { useQuery } from '@tanstack/react-query'
import { employeeTimesheetQueryKey, fetchEmployeeTimesheetDays } from './timesheetService'

export function useEmployeeTimesheet(
  siteId: string | null,
  employeeId: string | null,
  from: string,
  to: string,
) {
  return useQuery({
    queryKey: employeeTimesheetQueryKey(employeeId ?? '', from, to),
    queryFn: () => fetchEmployeeTimesheetDays(siteId!, employeeId!, from, to),
    enabled: !!siteId && !!employeeId && !!from && !!to,
    staleTime: 30_000,
  })
}
