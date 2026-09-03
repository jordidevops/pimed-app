import { useMutation } from '@tanstack/react-query'
import { getDocumentUrl } from './documentsService'

export function useGetDocumentUrl() {
  return useMutation({
    mutationFn: ({ versionId, expirySeconds }: { versionId: string; expirySeconds?: number }) =>
      getDocumentUrl(versionId, expirySeconds),
  })
}
