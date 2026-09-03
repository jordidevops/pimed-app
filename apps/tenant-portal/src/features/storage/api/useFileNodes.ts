import { useQuery } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { listFileNodes } from './storageService'
import type { FileNode } from '../types/storage.types'

/**
 * Lists the direct children of a directory within a tenant.
 * Pass `parentId = null` (default) to list the root.
 *
 * @example
 * // Root listing
 * const { data: files } = useFileNodes(tenantId)
 *
 * // Subfolder listing
 * const { data: files } = useFileNodes(tenantId, folderId)
 */
export function useFileNodes(
  tenantId: string | undefined,
  parentId: string | null = null,
  storageProviderId?: string | null,
  options?: { hideFieldWork?: boolean },
) {
  return useQuery<FileNode[]>({
    queryKey: [
      ...storageKeys.nodesByParent(tenantId ?? '', parentId, storageProviderId),
      options?.hideFieldWork ? 'hide_fw' : 'show_fw',
    ],
    queryFn: () =>
      listFileNodes(tenantId!, parentId, storageProviderId, {
        hideFieldWork: options?.hideFieldWork,
      }),
    enabled: !!tenantId,
  })
}
