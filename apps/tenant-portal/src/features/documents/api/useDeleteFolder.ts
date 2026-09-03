import { useMutation, useQueryClient } from '@tanstack/react-query'
import { documentsKeys } from './documentsKeys'
import { deleteFolder } from './documentsService'
import { useTenant } from '@/contexts/TenantContext'

export function useDeleteFolder(_parentId?: string | null) {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: (id: string) => deleteFolder(id),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: documentsKeys.allFolders(activeTenant?.id ?? ''),
      })
    },
  })
}
