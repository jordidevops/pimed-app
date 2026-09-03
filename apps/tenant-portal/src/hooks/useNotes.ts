import { useQuery } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'

export interface Note {
  id: string
  tenant_id: string
  site_id: string | null
  title: string
  content: string | null
  is_pinned: boolean
  created_by: string
  created_at: string
  updated_at: string
}

/**
 * Retorna les notes visibles per l'usuari en el context actual (tenant + site).
 *
 * Lògica de filtre:
 *   - tenantId null → notes de tots els tenants (RLS filtra via JWT claims)
 *   - tenantId + siteId null → "Vista Global": totes les notes del tenant
 *     (globals + de tots els sites). L'usuari ha de tenir global_role per arribar aquí.
 *   - tenantId + siteId → notes del site concret + globals (site_id = siteId OR NULL)
 */
export function useNotes(
  userId: string | undefined,
  tenantId: string | null,
  siteId: string | null,
) {
  return useQuery<Note[]>({
    queryKey: ['notes', tenantId, siteId, userId],
    enabled: !!userId,
    queryFn: async () => {
      let query = supabase
        .from('notes')
        .select('id, tenant_id, site_id, title, content, is_pinned, created_by, created_at, updated_at')
        .order('is_pinned', { ascending: false })
        .order('created_at', { ascending: false })

      if (tenantId) {
        query = query.eq('tenant_id', tenantId)
      }

      if (siteId) {
        // Notes del site concret + notes globals del tenant.
        query = query.or(`site_id.eq.${siteId},site_id.is.null`)
      }
      // siteId === null amb tenantId present → Vista Global (totes les notes del tenant,
      // incloent globals i de tots els sites). No cal filtre addicional.

      const { data, error } = await query
      if (error) throw error
      return data as Note[]
    },
  })
}

