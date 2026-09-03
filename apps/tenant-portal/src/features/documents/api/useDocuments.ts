import { useQuery } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { getActiveDocuments, type ActiveDocument } from './documentsService'
import { useTenant } from '@/contexts/TenantContext'

interface UseDocumentsOptions {
  folderId?: string | null
  entityType?: string | null
  entityId?: string | null
  siteId?: string | null
  allFolders?: boolean
  category?: string | null
}

export function useDocuments(options: UseDocumentsOptions = {}) {
  const { activeTenant } = useTenant()
  return useQuery<ActiveDocument[]>({
    queryKey: [
      ...documentsKeys.allDocs(activeTenant?.id ?? ''),
      options.allFolders ? '__all__' : (options.folderId ?? 'all'),
      options.entityType ?? null,
      options.entityId ?? null,
      options.siteId ?? null,
      options.category ?? null,
    ],
    queryFn: () =>
      getActiveDocuments({
        tenantId: activeTenant!.id!,
        folderId: options.folderId,
        entityType: options.entityType,
        entityId: options.entityId,
        siteId: options.siteId,
        allFolders: options.allFolders,
        category: options.category,
      }),
    enabled: !!activeTenant,
  })
}
