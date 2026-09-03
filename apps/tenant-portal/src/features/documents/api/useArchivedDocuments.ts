import { useQuery } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { getArchivedDocuments, type ArchivedDocument } from './documentsService'
import { useTenant } from '@/contexts/TenantContext'

interface UseArchivedDocumentsOptions {
  folderId?: string | null
  siteId?: string | null
}

export function useArchivedDocuments(options: UseArchivedDocumentsOptions = {}) {
  const { activeTenant } = useTenant()
  return useQuery<ArchivedDocument[]>({
    queryKey: [
      ...documentsKeys.allArchivedDocs(activeTenant?.id ?? ''),
      options.folderId ?? 'all',
      options.siteId ?? null,
    ],
    queryFn: () =>
      getArchivedDocuments({
        tenantId: activeTenant!.id!,
        folderId: options.folderId,
        siteId: options.siteId,
      }),
    enabled: !!activeTenant,
  })
}
