import { useMutation, useQueryClient } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { createFolder } from './storageService'
import type { StorageServiceError } from '../types/storage.types'

interface CreateFolderParams {
  name: string
}

export function useCreateFolder(tenantId: string, parentId: string | null) {
  const queryClient = useQueryClient()

  return useMutation<void, StorageServiceError, CreateFolderParams>({
    mutationFn: ({ name }) => createFolder(tenantId, name, parentId),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: storageKeys.nodesByParent(tenantId, parentId),
      })
    },
  })
}
