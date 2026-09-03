import { useQuery } from '@tanstack/react-query'
import { storageKeys } from './storageKeys'
import { getNodePermissions } from './storageService'

export function useNodePermissions(nodeId: string | null) {
  return useQuery({
    queryKey: storageKeys.permissionsByNode(nodeId ?? ''),
    queryFn: () => getNodePermissions(nodeId!),
    enabled: !!nodeId,
    staleTime: 30_000,
  })
}
