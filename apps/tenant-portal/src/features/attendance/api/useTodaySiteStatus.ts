import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'

export interface SiteStatusRow {
  tenant_id: string
  site_id: string
  employee_id: string
  employee_name: string
  current_state: 'outside' | 'working' | 'on_pause' | 'unknown'
  last_punch_type: string | null
  last_pause_type: string | null
  last_punch_at: string | null
  last_is_remote: boolean | null
  geo_lat: number | null
  geo_lng: number | null
  anomaly_codes: string[] | null
  needs_review: boolean
}

async function fetchSiteStatus(siteId: string | null): Promise<SiteStatusRow[]> {
  const { data, error } = await supabase.rpc(
    // @ts-expect-error RPC added in attendance v2 migration
    'get_today_site_status',
    { p_site_id: siteId ?? undefined },
  )
  if (error) throw new Error(error.message)
  return (data ?? []) as unknown as SiteStatusRow[]
}

export function useTodaySiteStatus() {
  const { selectedSiteId } = useTenant()
  return useQuery({
    queryKey: ['attendance', 'today-site-status', selectedSiteId],
    queryFn: () => fetchSiteStatus(selectedSiteId),
    refetchInterval: 60_000,
    staleTime: 30_000,
  })
}

export function usePendingAbsencesCount() {
  return useQuery({
    queryKey: ['attendance', 'pending-absences-count'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc(
        // @ts-expect-error RPC added in attendance v2 migration
        'count_pending_absences',
      )
      if (error) throw new Error(error.message)
      return (data as number) ?? 0
    },
    refetchInterval: 60_000,
  })
}
