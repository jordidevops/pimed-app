import { useQuery } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { getStorageUsageByDrive } from './storageService'
import type { StorageUsage } from '../types/storage.types'

/**
 * Fetches the storage quota summary (committed + reserved bytes, file count)
 * for a tenant. Returns null when the tenant has no usage row yet.
 *
 * @example
 * const { data: usage } = useStorageUsage(tenantId)
 * const usedMb = usage?.total_mb ?? 0
 */
export function useStorageUsage(tenantId: string | undefined, driveId?: string | null) {
  return useQuery<StorageUsage | null>({
    queryKey: storageKeys.usageByTenant(tenantId ?? '', driveId),
    queryFn: () => getStorageUsageByDrive(tenantId!, driveId),
    enabled: !!tenantId,
  })
}
