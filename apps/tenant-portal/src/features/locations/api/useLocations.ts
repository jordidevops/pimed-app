import { useQuery } from '@tanstack/react-query'
import { locationsKeys } from './locationsKeys'
import { getLocations } from './locationsService'
import type { Location } from './locationsService'
import { useTenant } from '@/contexts/TenantContext'

export function useLocations() {
  const { activeTenant, selectedSiteId } = useTenant()
  const hasSiteSelected = !!selectedSiteId

  return useQuery<Location[]>({
    queryKey: locationsKeys.list(activeTenant?.id ?? '', selectedSiteId),
    queryFn: () => {
      if (!selectedSiteId) return Promise.resolve([])
      return getLocations(selectedSiteId)
    },
    enabled: !!activeTenant && hasSiteSelected,
  })
}
