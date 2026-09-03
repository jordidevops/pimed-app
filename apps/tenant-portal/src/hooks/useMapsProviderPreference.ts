import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings } from '@/hooks/useSettings'
import {
  parseMapsProviderPreference,
  parseMapsSettings,
  type MapsProviderPreference,
} from '@/lib/maps/mapsSettings'

export type { MapsProviderPreference }
export { parseMapsProviderPreference, parseMapsSettings } from '@/lib/maps/mapsSettings'

/** Effective maps.provider for the active tenant (defaults to google / auto-BYO). */
export function useMapsProviderPreference() {
  const { activeTenant } = useTenant()
  const { data: effective, isLoading, error } = useEffectiveSettings({
    tenantId: activeTenant?.id ?? null,
  })

  const preference = parseMapsProviderPreference(effective?.maps)

  return { preference, isLoading, error }
}

/** Tenant-configured Map ID from settings (BYOK). Platform Map ID comes from the edge key response. */
export function useTenantMapsMapId() {
  const { activeTenant } = useTenant()
  const { data: effective, isLoading, error } = useEffectiveSettings({
    tenantId: activeTenant?.id ?? null,
  })

  return {
    mapId: parseMapsSettings(effective?.maps).mapId,
    isLoading,
    error,
  }
}
