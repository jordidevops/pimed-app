// Canonical geolocation shape shared by all entities with a map (sites, locations,
// contact_sites, and any future entity). See docs/plans/maps-geocoding-byok/README.md §5.0
// and docs/plans/maps-geocoding-byok/ADR-geo-coordinates.md — do not fork this shape locally.

export type GeoProvider = 'google' | 'nominatim' | 'manual' | 'device'
export type GeoSource = 'search' | 'reverse' | 'map_click' | 'manual_input' | 'geolocation'

export type GeoCoordinates = {
  lat: number
  lng: number
  street?: string | null
  street_number?: string | null
  city?: string | null
  province?: string | null
  postal_code?: string | null
  country_code?: string | null
  address?: string | null
  geocoding?: {
    provider: GeoProvider
    source: GeoSource
    providerData?: Record<string, unknown>
  }
}

export type StructuredAddress = {
  street?: string | null
  street_number?: string | null
  city?: string | null
  province?: string | null
  postal_code?: string | null
  country_code?: string | null
  address?: string | null
}

export function asFiniteNumber(value: unknown): number | null {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null
  if (typeof value === 'string') {
    const trimmed = value.trim()
    if (!trimmed) return null
    const parsed = Number(trimmed)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

function asOptionalString(value: unknown): string | null | undefined {
  if (value === null) return null
  if (typeof value === 'string') {
    const trimmed = value.trim()
    return trimmed.length > 0 ? trimmed : null
  }
  return undefined
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null
  return value as Record<string, unknown>
}

function asGeoProvider(value: unknown): GeoProvider | null {
  if (value === 'google' || value === 'nominatim' || value === 'manual' || value === 'device') {
    return value
  }
  return null
}

function asGeoSource(value: unknown): GeoSource | null {
  if (
    value === 'search' ||
    value === 'reverse' ||
    value === 'map_click' ||
    value === 'manual_input' ||
    value === 'geolocation'
  ) {
    return value
  }
  return null
}

/**
 * Parses an unknown value (typically a `geo_coordinates` jsonb column) into the
 * canonical shape used across the app. Also understands the legacy nested
 * `geocoding.address.*` layout in case older records stored structured fields there.
 */
export function parseGeoCoordinates(geo: unknown): {
  point: { lat: number; lng: number } | null
  address: StructuredAddress
  provider: GeoProvider | null
  source: GeoSource | null
  providerData?: Record<string, unknown>
} {
  const record = asRecord(geo)

  if (!record) {
    return { point: null, address: {}, provider: null, source: null }
  }

  const lat = asFiniteNumber(record.lat)
  const lng = asFiniteNumber(record.lng)
  const point = lat !== null && lng !== null ? { lat, lng } : null

  const geocoding = asRecord(record.geocoding)
  const legacyAddress = asRecord(geocoding?.address)

  const address: StructuredAddress = {
    street: asOptionalString(record.street) ?? asOptionalString(legacyAddress?.street),
    street_number:
      asOptionalString(record.street_number) ?? asOptionalString(legacyAddress?.street_number),
    city: asOptionalString(record.city) ?? asOptionalString(legacyAddress?.city),
    province: asOptionalString(record.province) ?? asOptionalString(legacyAddress?.province),
    postal_code:
      asOptionalString(record.postal_code) ?? asOptionalString(legacyAddress?.postal_code),
    country_code:
      asOptionalString(record.country_code) ?? asOptionalString(legacyAddress?.country_code),
    address: asOptionalString(record.address) ?? asOptionalString(legacyAddress?.address),
  }

  const provider = asGeoProvider(geocoding?.provider)
  const source = asGeoSource(geocoding?.source)
  const providerData = asRecord(geocoding?.providerData) ?? undefined

  return { point, address, provider, source, providerData }
}

/**
 * Builds a canonical `GeoCoordinates` value ready to persist in a `geo_coordinates`
 * jsonb column (or equivalent structured columns + jsonb mirror).
 */
export function buildGeoCoordinates(
  point: { lat: number; lng: number },
  address: StructuredAddress,
  meta?: { provider?: GeoProvider; source?: GeoSource; providerData?: Record<string, unknown> },
): GeoCoordinates {
  const geo: GeoCoordinates = {
    lat: point.lat,
    lng: point.lng,
    street: address.street ?? null,
    street_number: address.street_number ?? null,
    city: address.city ?? null,
    province: address.province ?? null,
    postal_code: address.postal_code ?? null,
    country_code: address.country_code ?? null,
    address: address.address ?? null,
  }

  if (meta?.provider && meta?.source) {
    geo.geocoding = {
      provider: meta.provider,
      source: meta.source,
      ...(meta.providerData ? { providerData: meta.providerData } : {}),
    }
  }

  return geo
}

/**
 * Formats a human-readable single-line address from structured fields, falling back
 * to the free-text `address` field when structured parts are missing.
 */
export function formatAddressLine(address: StructuredAddress): string {
  const streetPart = [address.street, address.street_number].filter(Boolean).join(' ').trim()
  const cityPart = [address.postal_code, address.city].filter(Boolean).join(' ').trim()
  const parts = [streetPart, cityPart, address.province, address.country_code].filter(
    (part) => typeof part === 'string' && part.trim().length > 0,
  )

  if (parts.length > 0) return parts.join(', ')
  return address.address?.trim() || ''
}

/**
 * Default entity name when the user leaves "Nom" empty:
 * `"Carrer, Número - Ciutat"` (US-A1 / contact sites).
 */
export function proposeLocationNameFromAddress(address: StructuredAddress): string {
  const street = address.street?.trim() || ''
  const number = address.street_number?.trim() || ''
  const city = address.city?.trim() || ''

  const streetPart =
    street && number ? `${street}, ${number}` : street || number

  if (streetPart && city) return `${streetPart} - ${city}`
  return streetPart || city || ''
}

export function googleMapsUrlFromGeo(geo: GeoCoordinates | null | undefined): string | null {
  if (!geo) return null
  const lat = asFiniteNumber(geo.lat)
  const lng = asFiniteNumber(geo.lng)
  if (lat === null || lng === null) return null
  return `https://www.google.com/maps/search/?api=1&query=${lat},${lng}`
}
