import { useQuery, keepPreviousData } from '@tanstack/react-query'
import {
  buildPlannerGridRows,
  fetchSchedulePlannerActuals,
  fetchSchedulePlannerDays,
  type PlannerActualRecord,
  type PlannerGridRow,
} from '../../api/schedulePlannerService'

export function useSchedulePlannerDays(
  siteId: string | null,
  from: string,
  to: string,
  tenantLabel: string,
  siteLabel: string,
) {
  return useQuery({
    queryKey: ['schedule-planner', 'days', siteId, from, to],
    queryFn: async (): Promise<PlannerGridRow[]> => {
      if (!siteId) return []
      const days = await fetchSchedulePlannerDays(siteId, from, to)
      return buildPlannerGridRows(days, tenantLabel, siteLabel)
    },
    enabled: !!siteId,
    staleTime: 30_000,
    placeholderData: keepPreviousData,
  })
}

export function useSchedulePlannerActuals(
  siteId: string | null,
  from: string,
  to: string,
  enabled = false,
) {
  return useQuery({
    queryKey: ['schedule-planner', 'actuals', siteId, from, to],
    queryFn: async (): Promise<PlannerActualRecord[]> => {
      if (!siteId) return []
      return fetchSchedulePlannerActuals(siteId, from, to)
    },
    enabled: !!siteId && enabled,
    staleTime: 30_000,
    placeholderData: keepPreviousData,
  })
}
