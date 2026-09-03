import { useMutation, useQueryClient } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { deleteDocumentLatestVersion } from './documentsService'

/**
 * Elimina la darrera versió d'un document.
 * Requereix ≥2 versions (error de domini si n'hi ha 1: cal usar useDeleteDocumentAll).
 * Invalida la llista de documents i l'historial de versions del document.
 */
export function useDeleteDocumentLatestVersion(tenantId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (documentId: string) => deleteDocumentLatestVersion(documentId),
    onSuccess: (_data, documentId) => {
      queryClient.invalidateQueries({ queryKey: documentsKeys.allDocs(tenantId) })
      queryClient.invalidateQueries({ queryKey: documentsKeys.versions(documentId) })
      queryClient.invalidateQueries({ queryKey: ['document', tenantId, documentId] })
    },
  })
}
