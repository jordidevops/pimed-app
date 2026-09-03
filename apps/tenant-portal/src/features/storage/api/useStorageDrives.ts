import { useQuery } from '@tanstack/react-query'
import { listStorageDrives } from './storageService'
import { storageKeys } from './storageKeys'
import type { StorageDrive } from '../types/storage.types'

/**
 * Fetches all BYOS storage drives for a tenant (up to 3).
 * Returns an empty array when no BYOS providers have been configured.
 * Only accessible by tenant owners and managers (enforced by RLS).
 */
export function useStorageDrives(tenantId: string | undefined) {
  return useQuery<StorageDrive[]>({
    queryKey: storageKeys.drivesByTenant(tenantId ?? ''),
    queryFn: () => listStorageDrives(tenantId!),
    enabled: !!tenantId,
  })
}
