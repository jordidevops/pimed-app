import { useMutation, useQueryClient } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { trashNode } from './storageService'

interface TrashNodeParams {
  nodeId: string
  /** true → permanent delete + enqueue Storage cleanup; false → soft trash (default) */
  forcePermanent?: boolean
}

/**
 * Moves a node to the trash (soft delete, 30-day retention) or permanently
 * deletes it when `forcePermanent = true`.
 *
 * On success, invalidates the file list, trash view, and storage quota so
 * all related queries update automatically.
 *
 * @example
 * const { mutate: trash } = useTrashNode(tenantId)
 * trash({ nodeId: file.id })                        // → soft delete
 * trash({ nodeId: file.id, forcePermanent: true })  // → hard delete
 */
export function useTrashNode(tenantId: string) {
  const queryClient = useQueryClient()

  return useMutation<number, Error, TrashNodeParams>({
    mutationFn: ({ nodeId, forcePermanent = false }) =>
      trashNode(nodeId, forcePermanent),

    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: storageKeys.nodes() })
      queryClient.invalidateQueries({ queryKey: storageKeys.trashByTenant(tenantId) })
      queryClient.invalidateQueries({ queryKey: storageKeys.usage() })
    },
  })
}
