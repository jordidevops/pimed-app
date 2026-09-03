import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { publicPortalKeys } from './queryKeys'
import type { Database } from '../../../types/database.types'

export type PublicPageRow = Database['api']['Views']['public_pages']['Row']
export type PublicPageFullRow = Database['api']['Views']['public_pages_full']['Row']

/**
 * Llista de pàgines d'un site amb camp content inclòs (public_pages_full).
 */
export function usePublicPages(tenantId: string | null | undefined, siteId: string | null | undefined) {
  return useQuery<PublicPageFullRow[]>({
    queryKey: publicPortalKeys.pages(tenantId ?? '', siteId ?? undefined),
    enabled: !!tenantId && !!siteId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('public_pages_full')
        .select('*')
        .eq('public_site_id', siteId!)
        .order('sort_order', { ascending: true })

      if (error) throw error
      return data ?? []
    },
    staleTime: 30_000,
  })
}

/**
 * Pàgina completa amb JSONB content (per a l'editor).
 */
export function usePublicPageFull(
  tenantId: string | null | undefined,
  siteId: string | null | undefined,
  pageId: string | null | undefined,
) {
  return useQuery<PublicPageFullRow | null>({
    queryKey: [...publicPortalKeys.pages(tenantId ?? '', siteId ?? undefined), pageId],
    enabled: !!tenantId && !!siteId && !!pageId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('public_pages_full')
        .select('*')
        .eq('id', pageId!)
        .maybeSingle()

      if (error) throw error
      return data
    },
    staleTime: 30_000,
  })
}
