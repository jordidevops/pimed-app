import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

/** Returns a map of documentId → active share link count for a list of document IDs. */
export function useShareLinkCountsBatch(documentIds: string[]) {
  return useQuery<Record<string, number>>({
    queryKey: ['document-share-link-counts', documentIds],
    queryFn: async () => {
      const uniq = Array.from(new Set(documentIds.filter(Boolean)))
      if (uniq.length === 0) return {}

      const { data, error } = await supabase
        .from('document_share_links')
        .select('document_id')
        .in('document_id', uniq)
        .eq('is_active', true)

      if (error) throw error

      const counts: Record<string, number> = {}
      for (const row of data ?? []) {
        const id = (row as any).document_id as string
        counts[id] = (counts[id] ?? 0) + 1
      }
      return counts
    },
    enabled: documentIds.length > 0,
    staleTime: 60_000,
  })
}
