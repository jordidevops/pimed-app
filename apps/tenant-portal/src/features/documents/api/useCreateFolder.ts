import { useMutation, useQueryClient } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { createFolder, type CreateFolderParams } from './documentsService'
import { useTenant } from '@/contexts/TenantContext'

export function useCreateFolder(_parentId?: string | null) {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: (params: CreateFolderParams) => createFolder(params),
    onSuccess: () => {
      // Invalida totes les queries de carpetes del tenant (global + embedded)
      queryClient.invalidateQueries({
        queryKey: documentsKeys.allFolders(activeTenant?.id ?? ''),
      })
    },
  })
}
