import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type ReadinessProjectionRow = {
  employee_id: string
  employee_name: string
  site_id: string | null
  department_id: string | null
  is_ready: boolean
  blocking_reasons: string[] | unknown
  configuration_status: string
  computed_at: string
}

export function useReadinessProjectionList(filters: {
  isReady?: boolean | null
  siteId?: string | null
  departmentId?: string | null
  limit?: number
}) {
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: [
      'readiness-projection-list',
      tenantId,
      filters.isReady ?? 'all',
      filters.siteId ?? '',
      filters.departmentId ?? '',
      filters.limit ?? 50,
    ],
    enabled: tenantScopeReady && !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_employee_readiness_projection', {
        p_is_ready: filters.isReady ?? undefined,
        p_site_id: filters.siteId || undefined,
        p_department_id: filters.departmentId || undefined,
        p_limit: filters.limit ?? 50,
        p_offset: 0,
      })
      if (error) throw error
      return (data ?? []) as ReadinessProjectionRow[]
    },
    staleTime: 15_000,
  })
}
