import { useMutation, useQueryClient } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { renameNode } from './storageService'
import type { StorageServiceError } from '../types/storage.types'

interface RenameNodeParams {
  nodeId: string
  newName: string
}

export function useRenameNode(_tenantId: string) {
  const queryClient = useQueryClient()

  return useMutation<void, StorageServiceError, RenameNodeParams>({
    mutationFn: ({ nodeId, newName }) => renameNode(nodeId, newName),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: storageKeys.nodes() })
    },
  })
}
