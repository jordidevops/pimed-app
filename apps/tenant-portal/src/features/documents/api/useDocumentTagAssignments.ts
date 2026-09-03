import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type DocumentTagAssignment = Database['api']['Views']['document_tag_assignments']['Row']

export function useDocumentTagAssignments(documentId: string | null | undefined) {
  return useQuery<DocumentTagAssignment[]>({
    queryKey: ['document-tag-assignments', documentId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('document_tag_assignments')
        .select('*')
        .eq('document_id', documentId!)
      if (error) throw error
      return data ?? []
    },
    enabled: !!documentId,
    staleTime: 30_000,
  })
}
