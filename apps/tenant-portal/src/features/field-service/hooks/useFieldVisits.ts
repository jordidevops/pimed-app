import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import { useAuth } from '@/contexts/AuthContext'
import {
  fieldVisitsKeys,
  invalidateFieldVisitQueries,
  listFieldVisits,
  type FieldVisit,
  type ListFieldVisitsParams,
} from '../api/fieldVisitsService'

export type FieldVisitsFilters = {
  from?: string | null
  to?: string | null
  types?: string[]
  memberIds?: string[] | null
  statuses?: string[] | null
  openOnly?: boolean
  unscheduled?: boolean
  /** When true, filter to current user as project member. */
  mineOnly?: boolean
  limit?: number
  enabled?: boolean
}

export function useFieldVisits(filters: FieldVisitsFilters) {
  const { activeTenant } = useTenant()
  const { user } = useAuth()
  const tenantId = activeTenant?.id
  const mineOnly = Boolean(filters.mineOnly)
  const memberIds =
    mineOnly && user?.id
      ? [user.id]
      : filters.memberIds?.length
        ? filters.memberIds
        : null

  const queryFilters = {
    from: filters.from ?? null,
    to: filters.to ?? null,
    types: filters.types ?? ['work_order', 'maintenance'],
    memberIds,
    statuses: filters.statuses ?? null,
    openOnly: filters.openOnly ?? true,
    unscheduled: filters.unscheduled ?? false,
    limit: filters.limit ?? 500,
    mineOnly,
    userId: mineOnly ? user?.id ?? null : null,
  }

  const enabled =
    Boolean(tenantId) &&
    (filters.enabled ?? true) &&
    (Boolean(filters.unscheduled) || Boolean(filters.from && filters.to)) &&
    // Avoid fetching "all visible" while auth is still resolving for mine scope.
    (!mineOnly || Boolean(user?.id))

  return useQuery({
    queryKey: fieldVisitsKeys.list(tenantId, queryFilters),
    enabled,
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<FieldVisit[]> => {
      if (!tenantId) return []
      const params: ListFieldVisitsParams = {
        tenantId,
        from: queryFilters.from,
        to: queryFilters.to,
        types: queryFilters.types,
        memberIds: queryFilters.memberIds,
        statuses: queryFilters.statuses,
        openOnly: queryFilters.openOnly,
        unscheduled: queryFilters.unscheduled,
        limit: queryFilters.limit,
      }
      return listFieldVisits(params)
    },
  })
}

export function useInvalidateFieldVisits() {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  return () => {
    invalidateFieldVisitQueries(queryClient, activeTenant?.id)
  }
}
