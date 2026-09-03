import { supabase } from '../supabase'

export interface GeocodeCandidate {
  lat: number
  lng: number
  displayName: string
  street?: string | null
  streetNumber?: string | null
  city?: string | null
  province?: string | null
  postalCode?: string | null
  countryCode?: string | null
  provider?: 'google' | 'nominatim'
  providerData?: Record<string, unknown>
}

export type NominatimErrorCode =
  | 'rate_limit'
  | 'nominatim_disabled'
  | 'service_unavailable'
  | 'quota_exceeded'
  | 'geocoding_blocked'
  | 'provider_denied'
  | 'request_failed'
  | 'network'

export class NominatimError extends Error {
  code: NominatimErrorCode
  status?: number
  /** Upstream error.code from geocoding-proxy when present */
  upstreamCode?: string

  constructor(
    message: string,
    code: NominatimErrorCode,
    status?: number,
    upstreamCode?: string,
  ) {
    super(message)
    this.name = 'NominatimError'
    this.code = code
    this.status = status
    this.upstreamCode = upstreamCode
  }
}

interface NominatimSearchResponseItem {
  place_id?: number
  lat: string
  lon: string
  osm_type?: string
  osm_id?: number
  type?: string
  class?: string
  importance?: number
  licence?: string
  address?: Record<string, unknown>
  display_name: string
}

interface NominatimReverseResponse {
  place_id?: number
  lat?: string
  lon?: string
  osm_type?: string
  osm_id?: number
  type?: string
  class?: string
  importance?: number
  licence?: string
  address?: Record<string, unknown>
  display_name?: string
}

interface StructuredAddressFields {
  street?: string | null
  street_number?: string | null
  city?: string | null
  province?: string | null
  postal_code?: string | null
  country_code?: string | null
}

interface SearchFunctionResponse {
  provider_key?: string
  results: Array<
    {
      lat: number
      lng: number
      display_name: string
      provider_data?: Record<string, unknown>
    } & StructuredAddressFields
  >
}

interface ReverseFunctionResponse {
  provider_key?: string
  result:
    | ({
        lat: number
        lng: number
        display_name: string
        provider_data?: Record<string, unknown>
      } & StructuredAddressFields)
    | null
}

function resolveProviderKey(
  providerKey: string | undefined,
  providerData?: Record<string, unknown>,
): 'google' | 'nominatim' {
  if (providerKey === 'google' || providerData?.provider === 'google') return 'google'
  return 'nominatim'
}

const FUNCTIONS_BASE = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1`

function normalizeLanguage(language?: string): string {
  if (!language) return 'ca'
  return language
}

function buildNominatimProviderData(
  endpoint: 'search' | 'reverse',
  item: NominatimSearchResponseItem | NominatimReverseResponse,
): Record<string, unknown> {
  return {
    provider: 'nominatim',
    endpoint,
    place_id: item.place_id ?? null,
    osm_type: item.osm_type ?? null,
    osm_id: item.osm_id ?? null,
    class: item.class ?? null,
    type: item.type ?? null,
    importance: item.importance ?? null,
    licence: item.licence ?? null,
    address: item.address ?? null,
  }
}

function mapProxyError(
  status: number,
  upstreamCode?: string,
  upstreamMessage?: string,
): NominatimErrorCode {
  const code = (upstreamCode ?? '').toLowerCase()
  const msg = (upstreamMessage ?? '').toLowerCase()

  if (msg.includes('nominatim_disabled') || code === 'nominatim_disabled') {
    return 'nominatim_disabled'
  }
  if (
    status === 402 ||
    code.startsWith('quota_') ||
    msg.startsWith('quota_')
  ) {
    return 'quota_exceeded'
  }
  if (
    code === 'provider_request_denied' ||
    msg.includes('request_denied') ||
    msg.includes('billing')
  ) {
    return 'provider_denied'
  }
  if (
    status === 429 ||
    code === 'provider_rate_limited' ||
    code.includes('rate_limit') ||
    msg.includes('rate_limit')
  ) {
    return 'rate_limit'
  }
  if (status >= 500) return 'service_unavailable'
  if (code === 'geocoding_blocked') {
    // Generic control-plane block without a more specific reason above.
    return 'geocoding_blocked'
  }
  return 'request_failed'
}

function getActiveTenantId(): string | null {
  // @supabase/postgrest-js stores headers as a Fetch Headers instance (.get/.set),
  // not a plain Record — bracket access always returns undefined.
  const restHeaders = (supabase as unknown as {
    rest?: { headers?: Headers }
  }).rest?.headers

  const tenantId = restHeaders?.get?.('x-tenant-id') ?? null
  return typeof tenantId === 'string' && tenantId.trim().length > 0 ? tenantId : null
}

async function callGeocodingProxy<T>(
  operation: 'search' | 'reverse',
  body: Record<string, unknown>,
): Promise<T> {
  const {
    data: { session },
  } = await supabase.auth.getSession()

  if (!session?.access_token) {
    throw new NominatimError('Missing user session', 'request_failed')
  }

  const tenantId = getActiveTenantId()
  if (!tenantId) {
    throw new NominatimError('Missing active tenant', 'request_failed')
  }

  try {
    const response = await fetch(`${FUNCTIONS_BASE}/geocoding-proxy`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${session.access_token}`,
        'x-tenant-id': tenantId,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify(body),
    })

    if (!response.ok) {
      const json = await response.json().catch(() => null)
      const upstreamCode =
        typeof json?.error?.code === 'string' ? json.error.code : undefined
      const message =
        json?.error?.message ||
        json?.message ||
        `Geocoding ${operation} failed with status ${response.status}`

      throw new NominatimError(
        message,
        mapProxyError(response.status, upstreamCode, message),
        response.status,
        upstreamCode,
      )
    }

    return (await response.json()) as T
  } catch (error) {
    if (error instanceof NominatimError) throw error
    throw new NominatimError(`Nominatim ${operation} network error`, 'network')
  }
}

export async function searchAddressWithNominatim(
  query: string,
  language?: string,
  limit = 5,
): Promise<GeocodeCandidate[]> {
  const trimmedQuery = query.trim()
  if (!trimmedQuery) return []

  const data = await callGeocodingProxy<SearchFunctionResponse>('search', {
    action: 'search',
    query: trimmedQuery,
    language: normalizeLanguage(language),
    limit: Math.max(1, Math.min(limit, 10)),
  })

  return data.results
    .map((item) => ({
      lat: Number(item.lat),
      lng: Number(item.lng),
      displayName: item.display_name,
      street: item.street ?? null,
      streetNumber: item.street_number ?? null,
      city: item.city ?? null,
      province: item.province ?? null,
      postalCode: item.postal_code ?? null,
      countryCode: item.country_code ?? null,
      provider: resolveProviderKey(data.provider_key, item.provider_data),
      providerData:
        item.provider_data ??
        buildNominatimProviderData('search', {
          lat: String(item.lat),
          lon: String(item.lng),
          display_name: item.display_name,
        }),
    }))
    .filter((item) => Number.isFinite(item.lat) && Number.isFinite(item.lng))
}

export async function reverseGeocodeWithNominatim(
  lat: number,
  lng: number,
  language?: string,
): Promise<GeocodeCandidate | null> {
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null

  const data = await callGeocodingProxy<ReverseFunctionResponse>('reverse', {
    action: 'reverse',
    lat,
    lng,
    language: normalizeLanguage(language),
  })

  if (!data.result?.display_name) return null

  const resolvedLat = Number(data.result.lat ?? lat)
  const resolvedLng = Number(data.result.lng ?? lng)

  return {
    lat: Number.isFinite(resolvedLat) ? resolvedLat : lat,
    lng: Number.isFinite(resolvedLng) ? resolvedLng : lng,
    displayName: data.result.display_name,
    street: data.result.street ?? null,
    streetNumber: data.result.street_number ?? null,
    city: data.result.city ?? null,
    province: data.result.province ?? null,
    postalCode: data.result.postal_code ?? null,
    countryCode: data.result.country_code ?? null,
    provider: resolveProviderKey(data.provider_key, data.result.provider_data),
    providerData:
      data.result.provider_data ??
      buildNominatimProviderData('reverse', {
        lat: String(resolvedLat),
        lon: String(resolvedLng),
        display_name: data.result.display_name,
      }),
  }
}
