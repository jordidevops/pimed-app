import { supabase } from '../supabase'
import { getFunctionErrorMessage } from '../functionErrors'

export type DistanceSource = 'google_routes' | 'haversine'

export interface LatLng {
  lat: number
  lng: number
}

export interface DistanceResult {
  source: DistanceSource
  distance_m: number
  duration_s: number | null
  is_approximate: boolean
}

export class RoutesError extends Error {
  code: string
  status?: number

  constructor(message: string, code: string, status?: number) {
    super(message)
    this.name = 'RoutesError'
    this.code = code
    this.status = status
  }
}

const EARTH_RADIUS_M = 6_371_000

/** Great-circle distance in metres (client-side sort/preview only). */
export function haversineDistanceM(a: LatLng, b: LatLng): number {
  const toRad = (d: number) => (d * Math.PI) / 180
  const dLat = toRad(b.lat - a.lat)
  const dLng = toRad(b.lng - a.lng)
  const sin =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(sin)))
}

export function formatDistanceKm(distanceM: number, locale: string): string {
  const km = distanceM / 1000
  const digits = km < 10 ? 1 : 0
  return new Intl.NumberFormat(locale, {
    maximumFractionDigits: digits,
    minimumFractionDigits: digits,
  }).format(km)
}

/**
 * Server-resolved distance: Google Routes BYO when configured, else haversine.
 * Never pass API keys from the client.
 */
export async function fetchDistance(
  tenantId: string,
  origin: LatLng,
  destination: LatLng,
): Promise<DistanceResult> {
  const { data, error } = await supabase.functions.invoke('routes-proxy', {
    headers: { 'x-tenant-id': tenantId },
    body: {
      action: 'distance',
      origin,
      destination,
    },
  })

  if (error) {
    throw new RoutesError(
      (await getFunctionErrorMessage(error)) ?? 'distance_failed',
      'request_failed',
    )
  }

  if (data?.error) {
    throw new RoutesError(
      data.error.message ?? 'distance_failed',
      data.error.code ?? 'request_failed',
    )
  }

  const result = data as DistanceResult
  if (
    !result ||
    typeof result.distance_m !== 'number' ||
    (result.source !== 'google_routes' && result.source !== 'haversine')
  ) {
    throw new RoutesError('invalid_distance_response', 'invalid_response')
  }

  return result
}
