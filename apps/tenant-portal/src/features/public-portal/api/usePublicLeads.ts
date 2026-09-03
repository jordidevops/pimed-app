import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { publicPortalKeys } from './queryKeys'
import type { Database } from '../../../types/database.types'

export type PublicLeadRow = Database['api']['Views']['public_leads']['Row']

export interface PublicLeadsFilters {
  siteId?: string
  status?: string
}

/**
 * Llista els leads del tenant actiu, amb filtre opcional per site i status.
 */
export function usePublicLeads(
  tenantId: string | null | undefined,
  filters: PublicLeadsFilters = {},
) {
  const queryFilters: Record<string, unknown> = {
    siteId: filters.siteId,
    status: filters.status,
  }

  return useQuery<PublicLeadRow[]>({
    queryKey: publicPortalKeys.leads(tenantId ?? '', queryFilters),
    enabled: !!tenantId,
    queryFn: async () => {
      let query = supabase
        .from('public_leads')
        .select('*')
        .order('created_at', { ascending: false })

      if (filters.siteId) {
        query = query.eq('public_site_id', filters.siteId)
      }
      if (filters.status) {
        query = query.eq('status', filters.status)
      }

      const { data, error } = await query
      if (error) throw error
      return data ?? []
    },
    staleTime: 15_000,
  })
}
