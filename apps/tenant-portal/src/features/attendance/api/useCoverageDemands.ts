import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type CoverageDemandKind = 'recurring' | 'extraordinary'

export type CoverageDemand = {
  id: string
  tenant_id: string
  site_id: string
  location_id: string | null
  role_id: string | null
  role_key: string | null
  role_name: string | null
  kind: CoverageDemandKind
  day_of_week: number | null
  demand_date: string | null
  start_time: string
  end_time: string
  required_min: number
  required_target: number
  required_max: number | null
  priority: number
  source: string
  name: string | null
  notes: string | null
  effective_from: string
  effective_to: string | null
  is_active: boolean
}

export function useCoverageDemands(siteId?: string | null) {
  const { activeTenant, selectedSiteId, tenantScopeReady } = useTenant()
  const resolvedSiteId = siteId ?? selectedSiteId
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: ['coverage-demands', tenantId, resolvedSiteId],
    enabled: tenantScopeReady && !!tenantId && !!resolvedSiteId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_coverage_demands' as never, {
        p_site_id: resolvedSiteId,
        p_include_inactive: false,
      } as never)
      if (error) throw error
      return (data ?? []) as CoverageDemand[]
    },
  })
}

export function useUpsertCoverageDemand() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (params: {
      id?: string | null
      site_id: string
      location_id?: string | null
      role_id?: string | null
      kind: CoverageDemandKind
      day_of_week?: number | null
      demand_date?: string | null
      start_time: string
      end_time: string
      required_min?: number
      required_target: number
      required_max?: number | null
      priority?: number
      name?: string | null
      clear_role?: boolean
    }) => {
      const { data, error } = await supabase.rpc('upsert_coverage_demand' as never, {
        p_id: params.id ?? null,
        p_site_id: params.site_id,
        p_location_id: params.location_id ?? null,
        p_role_id: params.role_id ?? null,
        p_kind: params.kind,
        p_day_of_week: params.day_of_week ?? null,
        p_demand_date: params.demand_date ?? null,
        p_start_time: params.start_time,
        p_end_time: params.end_time,
        p_required_min: params.required_min ?? 0,
        p_required_target: params.required_target,
        p_required_max: params.required_max ?? null,
        p_priority: params.priority ?? 100,
        p_source: 'manual',
        p_name: params.name ?? null,
        p_notes: null,
        p_effective_from: null,
        p_effective_to: null,
        p_is_active: true,
        p_clear_location: false,
        p_clear_role: params.clear_role ?? false,
      } as never)
      if (error) throw error
      return data
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['coverage-demands'] })
      void qc.invalidateQueries({ queryKey: ['attendance', 'coverage'] })
    },
  })
}

export function useDeactivateCoverageDemand() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc('deactivate_coverage_demand' as never, {
        p_id: id,
      } as never)
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['coverage-demands'] })
      void qc.invalidateQueries({ queryKey: ['attendance', 'coverage'] })
    },
  })
}
