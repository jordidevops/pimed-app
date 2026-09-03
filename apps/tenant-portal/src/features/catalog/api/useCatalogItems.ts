import { useQuery } from '@tanstack/react-query'
import { getCatalogItems } from './catalogService'
import type { CatalogItem } from './catalogService'
import { useTenant } from '@/contexts/TenantContext'

export const catalogItemsKeys = {
  all:  ['catalogItems'] as const,
  list: (tenantId: string) => ['catalogItems', 'list', tenantId] as const,
}

export function useCatalogItems() {
  const { activeTenant } = useTenant()
  return useQuery<CatalogItem[]>({
    queryKey: catalogItemsKeys.list(activeTenant?.id ?? ''),
    queryFn:  getCatalogItems,
    enabled:  !!activeTenant,
  })
}
