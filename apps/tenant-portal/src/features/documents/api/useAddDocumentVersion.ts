import { useMutation, useQueryClient } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { addDocumentVersion, type AddDocumentVersionParams } from './documentsService'
import { useTenant } from '@/contexts/TenantContext'

export function useAddDocumentVersion() {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: (params: AddDocumentVersionParams) => addDocumentVersion(params),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: documentsKeys.allDocs(activeTenant?.id ?? ''),
      })
    },
  })
}
