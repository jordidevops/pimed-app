import { useQuery } from '@tanstack/react-query'
import { fetchDistance, type DistanceResult, type LatLng } from '@/lib/maps/routes'
import { useTenant } from '@/contexts/TenantContext'

/**
 * Resolves road distance (Routes BYO) or haversine fallback via routes-proxy.
 */
export function useDistance(
  origin: LatLng | null | undefined,
  destination: LatLng | null | undefined,
  options?: { enabled?: boolean },
) {
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id ?? null
  const enabled =
    (options?.enabled ?? true) &&
    !!tenantId &&
    !!origin &&
    !!destination &&
    Number.isFinite(origin.lat) &&
    Number.isFinite(origin.lng) &&
    Number.isFinite(destination.lat) &&
    Number.isFinite(destination.lng)

  return useQuery<DistanceResult>({
    queryKey: [
      'routes-distance',
      tenantId,
      origin?.lat,
      origin?.lng,
      destination?.lat,
      destination?.lng,
    ],
    enabled,
    staleTime: 5 * 60_000,
    queryFn: () => fetchDistance(tenantId!, origin!, destination!),
  })
}
