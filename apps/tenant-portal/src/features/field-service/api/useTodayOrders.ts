import { useQuery } from '@tanstack/react-query'
import { getProjectsPage, type ProjectListResponse } from '@/features/projects/api/projectsService'
import { useTenant } from '@/contexts/TenantContext'
import { loadTodayCache, saveTodayCache } from '@/lib/today-cache'
import { useOnlineStatus } from '@/hooks/useOnlineStatus'
import { localDayRange, localDaysAheadRange } from '@/lib/dateLocal'

const FIELD_ORDER_TYPES = ['work_order', 'maintenance'] as const

async function fetchFieldOrders(
  tenantId: string,
  params: Parameters<typeof getProjectsPage>[1],
): Promise<ProjectListResponse> {
  const pages = await Promise.all(
    FIELD_ORDER_TYPES.map((type) => getProjectsPage(tenantId, { ...params, type })),
  )
  const seen = new Set<string>()
  const items = pages.flatMap((page) => page.items).filter((order) => {
    const id = order.id
    if (!id || seen.has(id)) return false
    seen.add(id)
    return FIELD_ORDER_TYPES.includes((order.type ?? '') as typeof FIELD_ORDER_TYPES[number])
  })
  return {
    items,
    totalCount: items.length,
    page: 1,
    pageSize: params.pageSize,
  }
}

export function useTodayOrders() {
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id
  const isOnline = useOnlineStatus()
  const { from, to, day } = localDayRange()

  return useQuery({
    queryKey: ['field-service', 'today-orders', tenantId, day],
    enabled: !!tenantId,
    queryFn: async (): Promise<ProjectListResponse & { fromCache?: boolean }> => {
      if (!tenantId) {
        return { items: [], totalCount: 0, page: 1, pageSize: 50 }
      }

      if (!isOnline) {
        const cached = await loadTodayCache(tenantId, day)
        if (cached) {
          return {
            items: cached.items,
            totalCount: cached.items.length,
            page: 1,
            pageSize: 50,
            fromCache: true,
          }
        }
        return { items: [], totalCount: 0, page: 1, pageSize: 50, fromCache: true }
      }

      const page = await fetchFieldOrders(tenantId, {
        page: 1,
        pageSize: 50,
        q: '',
        status: '',
        type: '',
        siteId: '',
        departmentId: '',
        plannedStartFrom: '',
        plannedStartTo: to,
        sortField: 'planned_start',
        sortDirection: 'asc',
        openOnly: true,
      })

      const startMs = new Date(from).getTime()
      const items = page.items.filter((order) => {
        const end = order.planned_end ? new Date(order.planned_end).getTime() : null
        return end === null || end >= startMs
      })

      await saveTodayCache(tenantId, day, items)
      return { ...page, items, totalCount: items.length }
    },
  })
}

/** Agenda: today + next 13 days (2 weeks window). */
export function useAgendaOrders() {
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id
  const isOnline = useOnlineStatus()
  const { from, to, day } = localDaysAheadRange(13)

  return useQuery({
    queryKey: ['field-service', 'agenda-orders', tenantId, day],
    enabled: !!tenantId,
    queryFn: async (): Promise<ProjectListResponse & { fromCache?: boolean }> => {
      if (!tenantId) {
        return { items: [], totalCount: 0, page: 1, pageSize: 100 }
      }

      if (!isOnline) {
        const cached = await loadTodayCache(tenantId, `agenda:${day}`)
        if (cached) {
          return {
            items: cached.items,
            totalCount: cached.items.length,
            page: 1,
            pageSize: 100,
            fromCache: true,
          }
        }
        return { items: [], totalCount: 0, page: 1, pageSize: 100, fromCache: true }
      }

      const page = await fetchFieldOrders(tenantId, {
        page: 1,
        pageSize: 100,
        q: '',
        status: '',
        type: '',
        siteId: '',
        departmentId: '',
        plannedStartFrom: from,
        plannedStartTo: to,
        sortField: 'planned_start',
        sortDirection: 'asc',
        openOnly: true,
      })

      await saveTodayCache(tenantId, `agenda:${day}`, page.items)
      return page
    },
  })
}
