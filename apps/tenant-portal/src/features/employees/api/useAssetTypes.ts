import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type AssetTypeCategory = 'epi' | 'vehicle' | 'tool' | 'device' | 'other'

export type AssetType = {
  id: string
  tenant_id: string | null
  code: string
  name: string
  category: AssetTypeCategory
  requires_return: boolean
  requires_calibration: boolean
  calibration_interval_days: number | null
  blocks_dispatch_if_missing: boolean
  is_active: boolean
  created_at: string
  updated_at: string
}

export function useAssetTypes(includeInactive = false) {
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id

  return useQuery({
    queryKey: ['asset-types', tenantId, includeInactive],
    enabled: tenantScopeReady && !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('list_asset_types', {
        p_include_inactive: includeInactive,
      })
      if (error) throw error
      return (data ?? []) as AssetType[]
    },
  })
}

export function useUpsertAssetType() {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()

  return useMutation({
    mutationFn: async (input: {
      id?: string | null
      code?: string | null
      name?: string | null
      category?: AssetTypeCategory | null
      requires_return?: boolean | null
      requires_calibration?: boolean | null
      calibration_interval_days?: number | null
      blocks_dispatch_if_missing?: boolean | null
      is_active?: boolean
    }) => {
      const { data, error } = await supabase.rpc('upsert_asset_type', {
        p_id: input.id ?? undefined,
        p_code: input.code ?? undefined,
        p_name: input.name ?? undefined,
        p_category: input.category ?? undefined,
        p_requires_return: input.requires_return ?? undefined,
        p_requires_calibration: input.requires_calibration ?? undefined,
        p_calibration_interval_days: input.calibration_interval_days ?? undefined,
        p_blocks_dispatch_if_missing: input.blocks_dispatch_if_missing ?? undefined,
        p_is_active: input.is_active ?? true,
      })
      if (error) throw error
      return data as AssetType
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['asset-types', activeTenant?.id] })
    },
  })
}
