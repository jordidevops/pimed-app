import { useQuery } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { listTrash } from './storageService'
import type { TrashedNode } from '../types/storage.types'

/**
 * Lists top-level trashed nodes for a tenant.
 * Only root-level trashed items are returned (descendants are implicit).
 *
 * @example
 * const { data: trashed } = useTrash(tenantId)
 */
export function useTrash(tenantId: string | undefined, driveId?: string | null) {
  return useQuery<TrashedNode[]>({
    queryKey: storageKeys.trashByTenant(tenantId ?? '', driveId),
    queryFn: () => listTrash(tenantId!, driveId),
    enabled: !!tenantId,
  })
}
