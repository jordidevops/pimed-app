import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type ReadinessProjectionSummary = {
  as_of: string
  site_id?: string | null
  department_id?: string | null
  total_employees: number
  ready: number
  not_ready: number
  unconfigured: number
  partial: number
  missing_projection: number
  ready_pct: number | null
}

export function useReadinessProjectionSummary(filters?: {
  siteId?: string | null
  departmentId?: string | null
}) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: [
      'readiness-projection-summary',
      activeTenant?.id ?? '',
      filters?.siteId ?? '',
      filters?.departmentId ?? '',
    ],
    enabled: !!activeTenant?.id,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_employee_readiness_projection_summary', {
        p_as_of: undefined,
        p_site_id: filters?.siteId || undefined,
        p_department_id: filters?.departmentId || undefined,
      })
      if (error) throw error
      return (data ?? {}) as ReadinessProjectionSummary
    },
    staleTime: 30_000,
  })
}
