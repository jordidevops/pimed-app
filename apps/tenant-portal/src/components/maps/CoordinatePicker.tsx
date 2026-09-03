import { useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { APIProvider, Map as GoogleMap, Marker } from '@vis.gl/react-google-maps'
import { useTenant } from '@/contexts/TenantContext'
import {
  NominatimError,
  type GeocodeCandidate,
} from '../../lib/maps/nominatim'
import { useGeocoding } from '../../hooks/useGeocoding'
import { useMapsProviderPreference } from '@/hooks/useMapsProviderPreference'
import { useMapsJsBrowserConfig } from '@/hooks/useMapsJsApiKey'
import type { GeoProvider, GeoSource, StructuredAddress } from '@/lib/geo/geoCoordinates'
import { cn } from '@/lib/utils'
import { supabase } from '@/lib/supabase'
import { classifyMapsJsClientError } from '@/lib/maps/classifyMapsJsClientError'

export interface CoordinatePoint {
  lat: number
  lng: number
}

export interface CoordinateSelectionContext extends StructuredAddress {
  address: string | null
  provider: GeoProvider
  source: GeoSource
  providerData?: Record<string, unknown>
}

interface CoordinatePickerProps {
  value: CoordinatePoint | null
  onChange: (value: CoordinatePoint | null) => void
  onContextChange?: (context: CoordinateSelectionContext | null) => void
  disabled?: boolean
  className?: string
  showHeader?: boolean
  /** Map viewport height class (default h-64 for dialogs). */
  mapClassName?: string
}

const DEFAULT_CENTER: CoordinatePoint = {
  lat: 41.3874,
  lng: 2.1686,
}

function normalizeCoordinateInput(value: string): string {
  return value.trim().replace(',', '.')
}

function parseCoordinateInput(value: string, min: number, max: number): number | null {
  const normalized = normalizeCoordinateInput(value)
  if (!normalized) return null
  const parsed = Number(normalized)
  if (!Number.isFinite(parsed)) return null
  if (parsed < min || parsed > max) return null
  return parsed
}

export function CoordinatePicker({
  value,
  onChange,
  onContextChange,
  disabled = false,
  className,
  showHeader = true,
  mapClassName = 'h-64',
}: CoordinatePickerProps) {
  const { t, i18n } = useTranslation('maps')
  const { searchAddress, reverseGeocode } = useGeocoding()
  const { preference: mapsProvider } = useMapsProviderPreference()
  const { activeTenant } = useTenant()
  const mapsJsQuery = useMapsJsBrowserConfig(true)
  const mapsJsApiKey = mapsJsQuery.data?.apiKey ?? null
  const mapsJsMapId = mapsJsQuery.data?.mapId ?? undefined
  const [selectedPoint, setSelectedPoint] = useState<CoordinatePoint | null>(value)
  const [selectionContext, setSelectionContext] = useState<CoordinateSelectionContext | null>(null)
  const [latInput, setLatInput] = useState('')
  const [lngInput, setLngInput] = useState('')
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<GeocodeCandidate[]>([])
  const [controlError, setControlError] = useState('')
  const [mapsJsLoadError, setMapsJsLoadError] = useState<string | null>(null)
  const [reverseAddress, setReverseAddress] = useState('')
  const [isSearching, setIsSearching] = useState(false)
  const [isLocating, setIsLocating] = useState(false)
  const reverseGenRef = useRef(0)

  const onContextChangeRef = useRef(onContextChange)
  onContextChangeRef.current = onContextChange

  function geocodingControlError(error: unknown, fallbackKey: 'search_error' | 'reverse_error', fallback: string): string {
    if (!(error instanceof NominatimError)) return t(fallbackKey, fallback)

    if (error.code === 'nominatim_disabled') {
      return t(
        'nominatim_disabled',
        'La cerca amb OpenStreetMap està desactivada temporalment. Marca el punt al mapa o configura Google a Configuració → Mapes.',
      )
    }
    if (error.code === 'quota_exceeded') {
      return t(
        'quota_exceeded',
        'La cerca amb Google està bloquejada (quota o facturació). Esborra la clau a Configuració → Mapes per tornar a OpenStreetMap, o revisa el compte GCP.',
      )
    }
    if (error.code === 'geocoding_blocked') {
      return t(
        'geocoding_blocked',
        'La geocodificació està bloquejada ara mateix. Torna-ho a provar o marca el punt al mapa.',
      )
    }
    if (error.code === 'provider_denied') {
      return t(
        'provider_denied',
        'Google ha denegat la petició (clau, APIs o facturació GCP). Esborra la clau per usar OpenStreetMap, o revisa Google Cloud.',
      )
    }
    if (error.code === 'rate_limit') {
      return t(
        'rate_limit',
        'Servei de mapes temporalment limitat. Torna-ho a provar en uns segons.',
      )
    }
    if (error.code === 'service_unavailable') {
      return t(
        'service_unavailable',
        'Servei de mapes no disponible temporalment. Torna-ho a provar mes tard.',
      )
    }
    return t(fallbackKey, fallback)
  }

  function applyPoint(nextPoint: CoordinatePoint | null, context?: CoordinateSelectionContext | null) {
    setSelectedPoint(nextPoint)
    if (typeof context !== 'undefined') {
      setSelectionContext(context)
    }
    onChange(nextPoint)
  }

  /** Wipe selection + UI feedback before a new search / geolocation. */
  function clearSelectionForNewAction(opts?: { clearQuery?: boolean }) {
    reverseGenRef.current += 1
    setResults([])
    setReverseAddress('')
    setControlError('')
    if (opts?.clearQuery) setQuery('')
    applyPoint(null, null)
  }

  useEffect(() => {
    setSelectedPoint(value)
  }, [value])

  useEffect(() => {
    setMapsJsLoadError(null)
  }, [mapsJsApiKey])

  const lastMapsJsErrorSigRef = useRef<string>('')
  const lastMapsJsErrorAtRef = useRef<number>(0)

  async function recordMapsJsClientError(category: string, code: string, origin: string) {
    const tenantId = activeTenant?.id
    if (!tenantId) return

    const sig = `${tenantId}|${category}|${code}|${origin}`
    const now = Date.now()
    if (lastMapsJsErrorSigRef.current === sig && now - lastMapsJsErrorAtRef.current < 10_000) return

    lastMapsJsErrorSigRef.current = sig
    lastMapsJsErrorAtRef.current = now

    try {
      await supabase.rpc('record_maps_js_client_error', {
        p_tenant_id: tenantId,
        p_category: category,
        p_code: code,
        p_origin: origin,
      })
    } catch {
      // El registre d'errors no ha de trencar la UI.
    }
  }

  useEffect(() => {
    if (!mapsJsApiKey) return
    const w = window as any

    w.gm_authFailure = () => {
      void recordMapsJsClientError('auth_failure', 'gm_authFailure', 'gm_authFailure')
    }

    return () => {
      if (w.gm_authFailure) delete w.gm_authFailure
    }
  }, [mapsJsApiKey, activeTenant?.id])

  useEffect(() => {
    onContextChangeRef.current?.(selectionContext)
  }, [selectionContext])

  useEffect(() => {
    if (!selectedPoint) {
      setLatInput('')
      setLngInput('')
      setReverseAddress('')
      return
    }
    setLatInput(selectedPoint.lat.toFixed(6))
    setLngInput(selectedPoint.lng.toFixed(6))
  }, [selectedPoint])

  useEffect(() => {
    if (!selectedPoint) return

    // Drop stale reverse text immediately when the point changes.
    setReverseAddress('')

    const gen = ++reverseGenRef.current
    let active = true
    const timeoutId = window.setTimeout(async () => {
      try {
        setControlError('')
        const displayName = await reverseGeocode(
          selectedPoint.lat,
          selectedPoint.lng,
          i18n.resolvedLanguage,
        )
        if (!active || gen !== reverseGenRef.current) return
        setReverseAddress(displayName?.displayName ?? '')
        if (displayName?.displayName) {
          setSelectionContext((previous) => {
            // Keep an explicit user action (search / geo / map / manual);
            // only fill address fields from reverse.
            if (previous?.source === 'search' && previous.address) {
              return previous
            }
            const keepSource =
              previous?.source === 'geolocation' ||
              previous?.source === 'map_click' ||
              previous?.source === 'manual_input'
                ? previous.source
                : 'reverse'
            return {
              address: displayName.displayName,
              street: displayName.street ?? null,
              street_number: displayName.streetNumber ?? null,
              city: displayName.city ?? null,
              province: displayName.province ?? null,
              postal_code: displayName.postalCode ?? null,
              country_code: displayName.countryCode ?? null,
              provider:
                keepSource === 'geolocation'
                  ? 'device'
                  : (displayName.provider ?? 'nominatim'),
              source: keepSource,
              providerData: displayName.providerData,
            }
          })
        }
      } catch (error) {
        if (!active || gen !== reverseGenRef.current) return
        setReverseAddress('')
        setControlError(
          geocodingControlError(
            error,
            'reverse_error',
            'No hem pogut obtenir l\'adreca per aquestes coordenades.',
          ),
        )
      }
    }, 450)

    return () => {
      active = false
      window.clearTimeout(timeoutId)
    }
  }, [selectedPoint, i18n.resolvedLanguage, reverseGeocode, t])

  const googleCenter = useMemo(() => {
    if (selectedPoint) return { lat: selectedPoint.lat, lng: selectedPoint.lng }
    return { lat: DEFAULT_CENTER.lat, lng: DEFAULT_CENTER.lng }
  }, [selectedPoint])

  const selectedZoom = selectedPoint ? 16 : 13

  const manualCoordinatesInvalid =
    (latInput.trim() || lngInput.trim()) &&
    (parseCoordinateInput(latInput, -90, 90) === null ||
      parseCoordinateInput(lngInput, -180, 180) === null)

  function updateManualCoordinates(nextLatInput: string, nextLngInput: string) {
    const parsedLat = parseCoordinateInput(nextLatInput, -90, 90)
    const parsedLng = parseCoordinateInput(nextLngInput, -180, 180)

    if (!nextLatInput.trim() && !nextLngInput.trim()) {
      applyPoint(null, null)
      setReverseAddress('')
      return
    }

    if (parsedLat === null || parsedLng === null) return
    setResults([])
    setReverseAddress('')
    applyPoint(
      { lat: parsedLat, lng: parsedLng },
      {
        address: null,
        provider: 'manual',
        source: 'manual_input',
        providerData: {
          provider: 'manual',
          endpoint: 'manual_input',
        },
      },
    )
  }

  async function handleSearch() {
    if (!query.trim()) {
      setResults([])
      return
    }

    clearSelectionForNewAction()
    setIsSearching(true)

    try {
      const found = await searchAddress(query, i18n.resolvedLanguage)
      setResults(found)
      if (found.length === 0) {
        setControlError(
          t(
            'no_results_pick_map',
            'No hem trobat resultats. Pots marcar el punt directament al mapa.',
          ),
        )
      }
    } catch (error) {
      setResults([])

      setControlError(
        geocodingControlError(
          error,
          'search_error',
          'No hem pogut completar la cerca ara mateix.',
        ),
      )
    } finally {
      setIsSearching(false)
    }
  }

  function handleSelectResult(result: GeocodeCandidate) {
    setResults([])
    setControlError('')
    setReverseAddress(result.displayName)
    applyPoint(
      { lat: result.lat, lng: result.lng },
      {
        address: result.displayName,
        street: result.street ?? null,
        street_number: result.streetNumber ?? null,
        city: result.city ?? null,
        province: result.province ?? null,
        postal_code: result.postalCode ?? null,
        country_code: result.countryCode ?? null,
        provider: result.provider ?? 'nominatim',
        source: 'search',
        providerData: result.providerData,
      },
    )
  }

  function handleUseMyLocation() {
    if (!navigator.geolocation) {
      setControlError(
        t('geo_not_supported', 'Aquest navegador no suporta geolocalitzacio.'),
      )
      return
    }

    clearSelectionForNewAction({ clearQuery: true })
    setIsLocating(true)

    navigator.geolocation.getCurrentPosition(
      (position) => {
        applyPoint(
          {
            lat: position.coords.latitude,
            lng: position.coords.longitude,
          },
          {
            address: null,
            provider: 'device',
            source: 'geolocation',
            providerData: {
              provider: 'device',
              endpoint: 'geolocation',
            },
          },
        )
        setIsLocating(false)
      },
      () => {
        setIsLocating(false)
        setControlError(
          t('geo_error', 'No hem pogut obtenir la teva ubicacio actual.'),
        )
      },
      {
        enableHighAccuracy: true,
        timeout: 12000,
      },
    )
  }

  const providerBadge = (() => {
    if (mapsJsQuery.isLoading) {
      return mapsProvider === 'google'
        ? t('basemap_badge_google_loading', 'Search: Google · Loading map…')
        : t('basemap_badge_osm_loading', 'Search: OpenStreetMap · Loading map…')
    }

    const visualMapAvailable = Boolean(mapsJsApiKey) && !mapsJsLoadError
    if (!visualMapAvailable) {
      return mapsProvider === 'google'
        ? t('basemap_badge_google_unavailable', 'Search: Google · Visual map not available')
        : t('basemap_badge_osm_unavailable', 'Search: OpenStreetMap · Visual map not available')
    }

    return mapsProvider === 'google'
      ? t('basemap_badge_google', 'Search: Google · Visual map: Google')
      : t('basemap_badge_osm_visual_google', 'Search: OpenStreetMap · Visual map: Google')
  })()

  const selectedSourceLabel = (() => {
    const source = selectionContext?.source
    const provider = selectionContext?.provider
    if (!source) return null
    if (source === 'search') {
      return provider === 'google'
        ? t('source_search_google', 'Resultat de cerca (Google)')
        : t('source_search_osm', 'Resultat de cerca (OpenStreetMap)')
    }
    if (source === 'geolocation') {
      return t('source_geolocation', 'La meva ubicació')
    }
    if (source === 'map_click' || source === 'manual_input') {
      return t('source_manual', 'Punt al mapa / manual')
    }
    if (source === 'reverse') {
      return t('source_reverse', 'Adreça del punt al mapa')
    }
    return null
  })()

  return (
    <div className={className ?? 'space-y-2'}>
      <div className="rounded-xl border border-border p-3 space-y-3 bg-background/30">
        {showHeader && (
          <div className="space-y-1">
            <p className="text-sm font-medium text-foreground">
              {t('title', 'Coordenades del site')}
            </p>
            <p className="text-xs text-muted-foreground">
              {t(
                'hint',
                'Fes clic al mapa per marcar el punt, o utilitza cerca i geolocalitzacio.',
              )}
            </p>
          </div>
        )}

        <div className="flex items-center justify-between gap-2">
          <p className="text-[11px] text-muted-foreground">{providerBadge}</p>
        </div>

        <div className="flex flex-col sm:flex-row gap-2">
          <input
            type="text"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key !== 'Enter') return
              event.preventDefault()
              void handleSearch()
            }}
            disabled={disabled || isSearching}
            placeholder={t('search_placeholder', 'Cerca una adreca o punt d\'interes')}
            className="w-full text-sm rounded-lg border border-input bg-background px-3 py-2 focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
          />
          <button
            type="button"
            onClick={() => {
              void handleSearch()
            }}
            disabled={disabled || isSearching}
            className="shrink-0 text-sm px-3 py-2 rounded-lg border border-border text-muted-foreground hover:bg-accent transition disabled:opacity-50"
          >
            {isSearching ? t('searching', 'Cercant...') : t('search', 'Buscar')}
          </button>
          <button
            type="button"
            onClick={handleUseMyLocation}
            disabled={disabled || isLocating}
            className="shrink-0 text-sm px-3 py-2 rounded-lg border border-border text-muted-foreground hover:bg-accent transition disabled:opacity-50"
          >
            {isLocating
              ? t('locating', 'Localitzant...')
              : t('use_my_location', 'La meva ubicacio')}
          </button>
        </div>

        {controlError && <p className="text-xs text-destructive">{controlError}</p>}

        {results.length > 0 && (
          <div className="space-y-1.5">
            <p className="text-xs font-medium text-foreground">
              {t('results_title', 'Resultats de la cerca')}
            </p>
            <p className="text-xs text-muted-foreground">
              {t(
                'select_result_hint',
                'Tria un resultat per marcar el punt. Si cap encaixa, clica al mapa.',
              )}
            </p>
            <ul className="rounded-lg border border-border divide-y divide-border overflow-hidden max-h-40 overflow-y-auto">
              {results.map((result) => (
                <li key={`${result.lat}-${result.lng}-${result.displayName}`}>
                  <button
                    type="button"
                    onClick={() => handleSelectResult(result)}
                    disabled={disabled}
                    className="w-full text-left px-3 py-2 text-sm hover:bg-accent transition disabled:opacity-50"
                  >
                    {result.displayName}
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )}

        <div className={cn('overflow-hidden rounded-lg border border-border', mapClassName)}>
          {mapsJsApiKey && !mapsJsLoadError ? (
            <APIProvider
              apiKey={mapsJsApiKey}
              libraries={[]}
              onLoad={() => {
                ;(window as any).__mapsJsLoaded = true
              }}
              onError={(error) => {
                const classified = classifyMapsJsClientError(error)
                void recordMapsJsClientError(
                  classified.category,
                  classified.code,
                  'api_provider_onError',
                )
                setMapsJsLoadError(t('maps_js_load_failed', "El mapa de Google no s'ha pogut carregar."))
              }}
            >
              <GoogleMap
                mapId={mapsJsMapId}
                className="h-full w-full"
                center={googleCenter}
                zoom={selectedZoom}
                onClick={(e) => {
                  if (disabled) return
                  const latLng = e.detail.latLng
                  if (!latLng) return
                  const point = { lat: latLng.lat, lng: latLng.lng }
                  setResults([])
                  setQuery('')
                  setReverseAddress('')
                  setControlError('')
                  setMapsJsLoadError(null)
                  applyPoint(point, {
                    address: null,
                    provider: 'manual',
                    source: 'map_click',
                    providerData: {
                      provider: 'manual',
                      endpoint: 'map_click',
                    },
                  })
                }}
              >
                {selectedPoint && (
                  <Marker position={{ lat: selectedPoint.lat, lng: selectedPoint.lng }} />
                )}
              </GoogleMap>
            </APIProvider>
          ) : (
            <div className="h-full w-full flex items-center justify-center text-xs text-muted-foreground bg-muted/20 p-3">
              {mapsJsQuery.isLoading
                ? t('maps_js_loading', 'Carregant mapa…')
                : mapsJsLoadError ?? t('maps_js_unavailable', 'Mapa visual no disponible')}
            </div>
          )}
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
          <input
            type="text"
            inputMode="decimal"
            value={latInput}
            onChange={(event) => {
              const next = event.target.value
              setLatInput(next)
              updateManualCoordinates(next, lngInput)
            }}
            disabled={disabled}
            placeholder={t('lat_placeholder', 'Latitud (ex: 41.387)')}
            className="w-full text-sm rounded-lg border border-input bg-background px-3 py-2 focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
          />
          <input
            type="text"
            inputMode="decimal"
            value={lngInput}
            onChange={(event) => {
              const next = event.target.value
              setLngInput(next)
              updateManualCoordinates(latInput, next)
            }}
            disabled={disabled}
            placeholder={t('lng_placeholder', 'Longitud (ex: 2.170)')}
            className="w-full text-sm rounded-lg border border-input bg-background px-3 py-2 focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
          />
        </div>

        {manualCoordinatesInvalid && (
          <p className="text-xs text-destructive">
            {t(
              'coordinates_invalid',
              'Coordenades no valides. Latitud entre -90 i 90, longitud entre -180 i 180.',
            )}
          </p>
        )}

        {selectedPoint && (reverseAddress || selectedSourceLabel) && (
          <div className="rounded-md bg-muted/40 px-3 py-2 space-y-0.5">
            {selectedSourceLabel && (
              <p className="text-[11px] font-medium text-foreground">{selectedSourceLabel}</p>
            )}
            {reverseAddress && (
              <p className="text-xs text-muted-foreground">
                {t('reverse_label', 'Adreca del punt')}: {reverseAddress}
              </p>
            )}
          </div>
        )}

        {selectedPoint && (
          <div className="flex justify-end">
            <button
              type="button"
              onClick={() => {
                clearSelectionForNewAction({ clearQuery: true })
              }}
              disabled={disabled}
              className="text-xs px-3 py-1.5 rounded-lg border border-border text-muted-foreground hover:bg-accent transition disabled:opacity-50"
            >
              {t('clear', 'Netejar coordenades')}
            </button>
          </div>
        )}
      </div>
    </div>
  )
}
