import { useQuery } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { listTenantMembers } from './storageService'

export function useTenantMembers(tenantId: string | undefined) {
  return useQuery({
    queryKey: storageKeys.tenantMembers(tenantId ?? ''),
    queryFn: () => listTenantMembers(tenantId!),
    enabled: !!tenantId,
    staleTime: 60_000,
  })
}
