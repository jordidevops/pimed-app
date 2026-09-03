import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import type { Database } from '../../../types/database.types'

type PortalUsageRow = Database['api']['Views']['portal_usage']['Row']

export function usePortalUsage(tenantId: string | null | undefined, siteId: string | null | undefined) {
  return useQuery<PortalUsageRow | null>({
    queryKey: ['portal-usage', tenantId ?? '', siteId ?? ''],
    enabled: !!tenantId && !!siteId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('portal_usage')
        .select('*')
        .eq('public_site_id', siteId!)
        .maybeSingle()
      if (error) throw error
      return data
    },
    staleTime: 30_000,
  })
}
