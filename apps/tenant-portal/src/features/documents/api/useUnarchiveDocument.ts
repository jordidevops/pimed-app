import { useMutation, useQueryClient } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { unarchiveDocument } from './documentsService'

export function useUnarchiveDocument(tenantId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (documentId: string) => unarchiveDocument(documentId),
    onSuccess: (_data, documentId) => {
      // Invalida la llista arxivada, la llista activa i el detall del document
      queryClient.invalidateQueries({ queryKey: documentsKeys.allArchivedDocs(tenantId) })
      queryClient.invalidateQueries({ queryKey: documentsKeys.allDocs(tenantId) })
      queryClient.invalidateQueries({ queryKey: ['document', tenantId, documentId] })
    },
  })
}
