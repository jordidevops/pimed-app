import { useQuery } from '@tanstack/react-query'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { listStarredFiles, starNode, unstarNode } from './storageService'
import type { StarredFile } from '../types/storage.types'

/**
 * Lists the current user's starred files within a tenant.
 * api.starred_files filters by auth.uid() server-side — no client-side filtering needed.
 *
 * @example
 * const { data: starred } = useStarredFiles(tenantId)
 */
export function useStarredFiles(tenantId: string | undefined, driveId?: string | null) {
  return useQuery<StarredFile[]>({
    queryKey: storageKeys.starredByTenant(tenantId ?? '', driveId),
    queryFn: () => listStarredFiles(tenantId!, driveId),
    enabled: !!tenantId,
  })
}

/**
 * Adds a node to the current user's starred list.
 * Silently ignores duplicate stars ('already_starred' code is not re-thrown).
 *
 * @example
 * const { mutate: star } = useStarNode(tenantId)
 * star(file.id)
 */
export function useStarNode(_tenantId: string) {
  const queryClient = useQueryClient()

  return useMutation<void, Error, string>({
    mutationFn: (nodeId) => starNode(nodeId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: storageKeys.starred() })
    },
  })
}

/**
 * Removes a node from the current user's starred list.
 *
 * @example
 * const { mutate: unstar } = useUnstarNode(tenantId)
 * unstar(file.id)
 */
export function useUnstarNode(_tenantId: string) {
  const queryClient = useQueryClient()

  return useMutation<void, Error, string>({
    mutationFn: (nodeId) => unstarNode(nodeId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: storageKeys.starred() })
    },
  })
}
