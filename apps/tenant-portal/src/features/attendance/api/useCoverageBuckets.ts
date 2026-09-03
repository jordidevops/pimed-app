import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export type CoverageBucketLayer = 'planned' | 'confirmed' | 'present' | 'qualified'

export type CoverageBucket = {
  bucket_start: string
  bucket_end: string
  bucket_start_min: number
  bucket_end_min: number
  required: number
  planned: number
  confirmed: number
  present: number
  qualified: number
  /** Alias EX-06.3 (= planned) */
  assigned: number
  gap: number
  gap_planned: number
  gap_confirmed: number
  gap_present: number
  gap_qualified: number
  role_id: string | null
  location_id: string | null
  require_shift_confirmation?: boolean
}

export function layerValue(b: CoverageBucket, layer: CoverageBucketLayer): number {
  switch (layer) {
    case 'confirmed':
      return b.confirmed ?? b.planned ?? b.assigned ?? 0
    case 'present':
      return b.present ?? 0
    case 'qualified':
      return b.qualified ?? 0
    case 'planned':
    default:
      return b.planned ?? b.assigned ?? 0
  }
}

export function layerGap(b: CoverageBucket, layer: CoverageBucketLayer): number {
  return layerValue(b, layer) - (b.required ?? 0)
}

export function useCoverageBuckets(params: {
  date: string
  bucketMinutes?: 15 | 30
  roleId?: string | null
  locationId?: string | null
  enabled?: boolean
}) {
  const { activeTenant, selectedSiteId, tenantScopeReady } = useTenant()
  const tenantId = activeTenant?.id
  const bucketMinutes = params.bucketMinutes ?? 30

  return useQuery({
    queryKey: [
      'coverage-buckets',
      tenantId,
      selectedSiteId,
      params.date,
      bucketMinutes,
      params.roleId ?? null,
      params.locationId ?? null,
    ],
    enabled:
      (params.enabled ?? true)
      && tenantScopeReady
      && !!tenantId
      && !!selectedSiteId
      && !!params.date,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_coverage_buckets' as never, {
        p_site_id: selectedSiteId,
        p_date: params.date,
        p_bucket_minutes: bucketMinutes,
        p_role_id: params.roleId ?? null,
        p_location_id: params.locationId ?? null,
      } as never)
      if (error) throw error
      return (data ?? []) as CoverageBucket[]
    },
  })
}
