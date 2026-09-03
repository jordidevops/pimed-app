import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useTenant } from '@/contexts/TenantContext'
import { MAP_ID_RE } from '@/lib/maps/mapsSettings'

type MapsJsBrowserKeyResponse =
  | { ok: true; apiKey: string; mapId?: string | null; source?: string }
  | { ok: false; code?: string }

export type MapsJsBrowserConfig = {
  apiKey: string
  mapId: string | null
  source: 'byok' | 'platform' | 'unknown'
}

/**
 * Fetches Maps JS browser API key (+ Map ID) for the active tenant.
 * Map ID: BYOK → tenant settings; platform trial → system_settings / env.
 */
export function useMapsJsBrowserConfig(enabled: boolean) {
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id ?? null

  return useQuery({
    queryKey: ['maps_js_browser_config', tenantId],
    enabled: enabled && !!tenantId,
    queryFn: async (): Promise<MapsJsBrowserConfig | null> => {
      const { data, error } = await supabase.functions.invoke('get-maps-js-browser-key', {
        headers: { 'x-tenant-id': tenantId! },
      })

      if (error) return null

      const res = data as MapsJsBrowserKeyResponse
      if (!res || !('ok' in res) || !res.ok) return null

      const mapIdRaw = typeof res.mapId === 'string' ? res.mapId.trim() : ''
      const mapId = mapIdRaw && MAP_ID_RE.test(mapIdRaw) ? mapIdRaw : null
      const source =
        res.source === 'byok' || res.source === 'platform' ? res.source : 'unknown'

      return {
        apiKey: res.apiKey,
        mapId,
        source,
      }
    },
    staleTime: 5 * 60 * 1000,
  })
}

/** Convenience: API key only (same query as useMapsJsBrowserConfig). */
export function useMapsJsApiKey(enabled: boolean) {
  const q = useMapsJsBrowserConfig(enabled)
  return {
    ...q,
    data: q.data?.apiKey ?? null,
  }
}
