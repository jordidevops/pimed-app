import { useQuery } from '@tanstack/react-query'
import { fetchUnresolvedOperationCount } from '@/features/operations/api/operationsRpc'

export function useUnresolvedOperationCount(tenantId: string | undefined, enabled: boolean) {
  return useQuery({
    queryKey: ['unresolved-operation-count', tenantId],
    queryFn: () => fetchUnresolvedOperationCount(tenantId!),
    enabled: Boolean(tenantId && enabled),
    staleTime: 60_000,
    refetchInterval: 120_000,
  })
}
