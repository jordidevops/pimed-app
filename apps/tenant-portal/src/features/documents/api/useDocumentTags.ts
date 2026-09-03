import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'
import type { Database } from '@/types/database.types'

export type DocumentTag = Database['api']['Views']['document_tags']['Row']

export function useDocumentTags() {
  const { activeTenant } = useTenant()
  return useQuery<DocumentTag[]>({
    queryKey: ['document-tags', activeTenant?.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('document_tags')
        .select('*')
        .eq('tenant_id', activeTenant!.id!)
        .order('name')
      if (error) throw error
      return data ?? []
    },
    enabled: !!activeTenant,
    staleTime: 5 * 60_000,
  })
}
