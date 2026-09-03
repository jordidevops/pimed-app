import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type AssetRequirementRule = {
  id: string
  tenant_id: string
  asset_type_id: string
  scope_type: 'tenant' | 'department' | 'job_position' | 'site'
  scope_id: string | null
  is_blocking: boolean
  is_active: boolean
  created_by: string
  created_at: string
  updated_at: string
}

export function useAssetRequirementRules(includeInactive = false) {
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: ['asset-requirement-rules', tenantId, includeInactive],
    enabled: tenantScopeReady && !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_asset_requirement_rules', {
        p_include_inactive: includeInactive,
      })
      if (error) throw error
      return (data ?? []) as AssetRequirementRule[]
    },
  })
}

export function useUpsertAssetRequirementRule() {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()

  return useMutation({
    mutationFn: async (input: {
      id?: string | null
      asset_type_id?: string | null
      scope_type?: AssetRequirementRule['scope_type'] | null
      scope_id?: string | null
      is_blocking?: boolean | null
      is_active?: boolean
    }) => {
      const { data, error } = await supabase.rpc('upsert_asset_requirement_rule', {
        p_id: input.id ?? undefined,
        p_asset_type_id: input.asset_type_id ?? undefined,
        p_scope_type: input.scope_type ?? undefined,
        p_scope_id: input.scope_id ?? undefined,
        p_is_blocking: input.is_blocking ?? undefined,
        p_is_active: input.is_active ?? true,
      })
      if (error) throw error
      return data as AssetRequirementRule
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['asset-requirement-rules', activeTenant?.id] })
      void qc.invalidateQueries({ queryKey: ['readiness-projection-summary', activeTenant?.id] })
    },
  })
}
