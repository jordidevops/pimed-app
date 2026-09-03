import { useMutation, useQueryClient } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { updateNodePermissions } from './storageService'
import type { StorageServiceError, UpdateNodePermissionsParams } from '../types/storage.types'

export function useUpdateNodePermissions(_tenantId: string) {
  const queryClient = useQueryClient()

  return useMutation<void, StorageServiceError, UpdateNodePermissionsParams>({
    mutationFn: updateNodePermissions,
    onSuccess: (_data, variables) => {
      // Invalidate permissions cache for the node
      queryClient.invalidateQueries({
        queryKey: storageKeys.permissionsByNode(variables.nodeId),
      })
      // Invalidate all file node listings so is_restricted / can_access_for_me refresh
      queryClient.invalidateQueries({
        queryKey: storageKeys.nodes(),
      })
    },
  })
}
