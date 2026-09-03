import { useMutation, useQueryClient } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { updateFolder, type UpdateFolderParams } from './documentsService'
import { useTenant } from '@/contexts/TenantContext'

export function useUpdateFolder(_parentId?: string | null) {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: ({ id, params }: { id: string; params: UpdateFolderParams }) =>
      updateFolder(id, params),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: documentsKeys.allFolders(activeTenant?.id ?? ''),
      })
    },
  })
}
