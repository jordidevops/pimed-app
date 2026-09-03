import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

interface FolderCount {
  /** Nombre de subcarpetes directes */
  folders: number
  /** Nombre de documents directes */
  docs: number
}

/**
 * Retorna els counts de contingut per a una llista de carpetes.
 * Fa exactament 2 queries (una per subcarpetes, una per documents),
 * independentment del nombre de carpetes.
 */
export function useFolderCounts(
  tenantId: string,
  folderIds: string[],
): Record<string, FolderCount> {
  const enabled = folderIds.length > 0 && !!tenantId

  const subQ = useQuery({
    queryKey: ['folder-counts-sub', tenantId, folderIds],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('document_folders')
        .select('parent_id')
        .eq('tenant_id', tenantId)
        .in('parent_id', folderIds)
      if (error) throw error
      return (data ?? []).reduce<Record<string, number>>((acc, r) => {
        if (r.parent_id) acc[r.parent_id] = (acc[r.parent_id] ?? 0) + 1
        return acc
      }, {})
    },
    enabled,
    staleTime: 60_000,
  })

  const docQ = useQuery({
    queryKey: ['folder-counts-docs', tenantId, folderIds],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('active_documents')
        .select('folder_id')
        .eq('tenant_id', tenantId)
        .in('folder_id', folderIds)
      if (error) throw error
      return (data ?? []).reduce<Record<string, number>>((acc, r) => {
        if (r.folder_id) acc[r.folder_id] = (acc[r.folder_id] ?? 0) + 1
        return acc
      }, {})
    },
    enabled,
    staleTime: 60_000,
  })

  const subMap = subQ.data ?? {}
  const docMap = docQ.data ?? {}

  return folderIds.reduce<Record<string, FolderCount>>((acc, id) => {
    acc[id] = { folders: subMap[id] ?? 0, docs: docMap[id] ?? 0 }
    return acc
  }, {})
}
