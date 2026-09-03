import { useMutation, useQueryClient } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { archiveDocument } from './documentsService'

export function useArchiveDocument(tenantId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (documentId: string) => archiveDocument(documentId),
    onSuccess: (_data, documentId) => {
      // Invalida la llista activa, la llista arxivada i el detall del document
      queryClient.invalidateQueries({ queryKey: documentsKeys.allDocs(tenantId) })
      queryClient.invalidateQueries({ queryKey: documentsKeys.allArchivedDocs(tenantId) })
      queryClient.invalidateQueries({ queryKey: ['document', tenantId, documentId] })
    },
  })
}
