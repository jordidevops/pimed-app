import { useQuery } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { getDocumentVersions, type DocumentVersion } from './documentsService'

export function useDocumentVersions(documentId: string | null | undefined) {
  return useQuery<DocumentVersion[]>({
    queryKey: documentsKeys.versions(documentId ?? ''),
    queryFn: () => getDocumentVersions(documentId!),
    enabled: !!documentId,
  })
}
