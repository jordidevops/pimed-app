import { useQuery } from '@tanstack/react-query'
import { employeePortalKeys } from './employeePortalKeys'
import { listEmployeePortalAccessOverview } from './employeePortalOverviewService'
import type { PortalAccessOverviewQuery } from './employeePortalOverviewTypes'

export function useEmployeePortalOverview(query: PortalAccessOverviewQuery, enabled = true) {
  return useQuery({
    queryKey: employeePortalKeys.overview(query),
    queryFn: () => listEmployeePortalAccessOverview(query),
    enabled,
    staleTime: 15_000,
  })
}
