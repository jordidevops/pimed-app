import { useMutation, useQueryClient } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { restoreNode } from './storageService'

/**
 * Restores a trashed node (and its descendants when it's a folder)
 * back to its original location.
 *
 * Invalidates both the trash view and the file listing so the restored
 * item immediately appears in the right directory.
 *
 * @example
 * const { mutate: restore } = useRestoreNode(tenantId)
 * restore(trashedNode.id)
 */
export function useRestoreNode(tenantId: string) {
  const queryClient = useQueryClient()

  return useMutation<number, Error, string>({
    mutationFn: (nodeId) => restoreNode(nodeId),

    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: storageKeys.nodes() })
      queryClient.invalidateQueries({ queryKey: storageKeys.trashByTenant(tenantId) })
    },
  })
}
