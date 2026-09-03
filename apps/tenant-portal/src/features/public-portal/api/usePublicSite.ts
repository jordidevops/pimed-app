import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { publicPortalKeys } from './queryKeys'
import type { Database } from '../../../types/database.types'

export type PublicSiteRow = Database['api']['Views']['public_sites']['Row']
export type PublicSiteFullRow = Database['api']['Views']['public_sites_full']['Row']

/**
 * Retorna el flag `public_portal_enabled` per al tenant actiu, fins i tot quan
 * no existeix cap site. Usada pel guard de PublicPortalPage.
 * No requereix la capçalera x-tenant-id perquè filtra per jwt_user_tenants().
 */
export function usePublicPortalStatus(tenantId: string | null | undefined) {
  return useQuery<boolean | null>({
    queryKey: ['public-portal-status', tenantId ?? ''],
    enabled: !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('my_public_portal_status')
        .select('public_portal_enabled')
        .maybeSingle()

      if (error) throw error
      return data?.public_portal_enabled ?? null
    },
    staleTime: 60_000,
  })
}

/**
 * Retorna el primer public_site del tenant actiu (llista lleugera, sense JSONB).
 */
export function usePublicSite(tenantId: string | null | undefined) {
  return useQuery<PublicSiteRow | null>({
    queryKey: publicPortalKeys.site(tenantId ?? ''),
    enabled: !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('public_sites')
        .select('*')
        .order('created_at', { ascending: true })
        .limit(1)
        .maybeSingle()

      if (error) throw error
      return data
    },
    staleTime: 30_000,
  })
}

/**
 * Retorna el public_site amb contingut JSONB complet (per a l'editor).
 */
export function usePublicSiteFull(tenantId: string | null | undefined) {
  return useQuery<PublicSiteFullRow | null>({
    queryKey: [...publicPortalKeys.site(tenantId ?? ''), 'full'],
    enabled: !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('public_sites_full')
        .select('*')
        .order('created_at', { ascending: true })
        .limit(1)
        .maybeSingle()

      if (error) throw error
      return data
    },
    staleTime: 30_000,
  })
}
