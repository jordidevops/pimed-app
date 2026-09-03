import { useQuery } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import {
  fetchTenantTimelineFeatures,
  tenantFeaturesKeys,
  type TenantTimelineFeatures,
} from './tenantFeaturesService'

export function useTenantFeatures() {
  const { activeTenant, tenantScopeReady } = useTenant()

  return useQuery<TenantTimelineFeatures>({
    queryKey: tenantFeaturesKeys.tenant(activeTenant?.id ?? ''),
    queryFn: fetchTenantTimelineFeatures,
    enabled: !!activeTenant?.id && tenantScopeReady,
    staleTime: 60_000,
  })
}
