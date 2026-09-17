import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { ActiveDocument } from './documentsService'

export function useDocument(documentId: string | undefined, tenantId: string | undefined) {
  return useQuery<ActiveDocument | null>({
    queryKey: ['document', tenantId ?? '', documentId ?? ''],
    queryFn: async () => {
      let query = supabase
        .from('active_documents')
        .select('*')
        .eq('id', documentId!)

      if (tenantId) {
        query = query.eq('tenant_id', tenantId)
      }

      const { data, error } = await query.maybeSingle()

      if (error) throw error
      return data ?? null
    },
    enabled: !!documentId && !!tenantId &&
      /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(documentId),
    staleTime: 30_000,
  })
}
