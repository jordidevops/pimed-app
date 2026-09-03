import { useMutation, useQueryClient } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { deleteDocumentAll } from './documentsService'

/**
 * Elimina el document complet (totes les versions i fitxers físics via worker).
 * Invalida la llista de documents del tenant.
 */
export function useDeleteDocumentAll(tenantId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (documentId: string) => deleteDocumentAll(documentId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: documentsKeys.allDocs(tenantId) })
    },
  })
}
