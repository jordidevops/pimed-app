/** Shared Maps settings parsers (tenant.settings.maps). */

export type MapsProviderPreference = 'google' | 'openstreetmap'

export type MapsSettingsBlob = {
  provider?: string
  map_id?: string | null
}

/** Google Map ID: alphanumeric with optional hyphens/underscores; not a secret. */
export const MAP_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_\-]{5,100}$/

export function parseMapsSettings(raw: unknown): {
  provider: MapsProviderPreference
  mapId: string | null
} {
  const blob =
    raw && typeof raw === 'object' ? (raw as MapsSettingsBlob) : ({} as MapsSettingsBlob)

  const providerRaw = String(blob.provider ?? '')
    .trim()
    .toLowerCase()
  const provider: MapsProviderPreference =
    providerRaw === 'openstreetmap' ? 'openstreetmap' : 'google'

  const mapIdRaw = typeof blob.map_id === 'string' ? blob.map_id.trim() : ''
  const mapId = mapIdRaw && MAP_ID_RE.test(mapIdRaw) ? mapIdRaw : null

  return { provider, mapId }
}

export function parseMapsProviderPreference(raw: unknown): MapsProviderPreference {
  return parseMapsSettings(raw).provider
}

export function normalizeMapIdInput(value: string): string | null {
  const trimmed = value.trim()
  if (!trimmed) return null
  if (!MAP_ID_RE.test(trimmed)) return null
  return trimmed
}
