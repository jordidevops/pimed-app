import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { publicPortalKeys } from './queryKeys'
import type { Database } from '../../../types/database.types'

export type PublicDomainRow = Database['api']['Views']['public_domains']['Row']

/**
 * Llista els dominis propis associats a un public_site.
 */
export function usePublicDomains(
  tenantId: string | null | undefined,
  siteId: string | null | undefined,
) {
  return useQuery<PublicDomainRow[]>({
    queryKey: publicPortalKeys.domains(tenantId ?? '', siteId ?? undefined),
    enabled: !!tenantId && !!siteId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('public_domains')
        .select('*')
        .eq('public_site_id', siteId!)
        .order('created_at', { ascending: true })

      if (error) throw error
      return data ?? []
    },
    staleTime: 20_000,
  })
}
