import { useMutation, useQueryClient } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { updateDocument } from './documentsService'
import { useTenant } from '@/contexts/TenantContext'

interface UpdateDocumentParams {
  documentId: string
  params: { category?: string | null; folder_id?: string | null; title?: string }
}

export function useUpdateDocument() {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()

  return useMutation({
    mutationFn: ({ documentId, params }: UpdateDocumentParams) =>
      updateDocument(documentId, params),
    onSuccess: (_data, { documentId }) => {
      queryClient.invalidateQueries({
        queryKey: documentsKeys.allDocs(activeTenant?.id ?? ''),
      })
      queryClient.invalidateQueries({
        queryKey: ['document', activeTenant?.id ?? '', documentId],
      })
    },
  })
}
