import { useMutation, useQueryClient } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { createDocumentWithVersion, type CreateDocumentWithVersionParams } from './documentsService'
import { useTenant } from '@/contexts/TenantContext'

export function useCreateDocument(
  _folderId?: string | null,
  _entityType?: string | null,
  _entityId?: string | null,
) {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: (params: CreateDocumentWithVersionParams) => createDocumentWithVersion(params),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: documentsKeys.allDocs(activeTenant?.id ?? ''),
      })
    },
  })
}
