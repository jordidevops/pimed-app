import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { CheckCircle2, MapPin, Route, Save, ShieldAlert, Trash2 } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { useTenantSettingsMutation, useEffectiveSettings } from '@/hooks/useSettings'
import {
  parseMapsSettings,
  type MapsProviderPreference,
} from '@/hooks/useMapsProviderPreference'
import { normalizeMapIdInput } from '@/lib/maps/mapsSettings'
import { supabase } from '@/lib/supabase'
import { getFunctionErrorMessage } from '@/lib/functionErrors'
import { listTenantSecrets } from '@/features/secrets/api/secretsService'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'

const GOOGLE_KEY_RE = /^[A-Za-z0-9\-_.]{20,200}$/

type KeyType = 'geocoding' | 'routes' | 'maps_js'

function formatUpdatedAt(iso: string | null | undefined, locale: string): string | null {
  if (!iso) return null
  try {
    return new Intl.DateTimeFormat(locale, { dateStyle: 'short', timeStyle: 'short' }).format(new Date(iso))
  } catch {
    return iso
  }
}

function useMapSecretStatus(
  rows: Awaited<ReturnType<typeof listTenantSecrets>> | undefined,
  secretType: 'geocoding_api_key' | 'routes_api_key' | 'maps_js_api_key',
) {
  return useMemo(() => {
    const list = rows ?? []
    const active = list.find(
      (r) =>
        r.secret_type === secretType &&
        r.provider === 'google' &&
        r.rotation_status === 'active',
    )
    const pending = list.find(
      (r) =>
        r.secret_type === secretType &&
        r.provider === 'google_pending' &&
        (r.rotation_status === 'pending_verification' || r.rotation_status === 'failed'),
    )
    return { active, pending }
  }, [rows, secretType])
}

function MapKeyCard({
  keyType,
  title,
  statusNone,
  guide1,
  guide2,
  secret,
}: {
  keyType: KeyType
  title: string
  statusNone: string
  guide1: string
  guide2: string
  secret: ReturnType<typeof useMapSecretStatus>
}) {
  const { t, i18n } = useTranslation('maps')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id ?? null

  const [apiKey, setApiKey] = useState('')
  const [testMessage, setTestMessage] = useState<string | null>(null)

  const saveMutation = useMutation({
    mutationFn: async () => {
      if (!tenantId) throw new Error('missing_tenant')
      const trimmed = apiKey.trim()
      if (!GOOGLE_KEY_RE.test(trimmed)) {
        throw new Error(t('settings.invalid_key_format', 'Format de clau invàlid'))
      }
      const { data, error } = await supabase.functions.invoke('save-map-api-key', {
        headers: { 'x-tenant-id': tenantId },
        body: { keyType, apiKey: trimmed },
      })
      if (error) throw new Error((await getFunctionErrorMessage(error)) ?? 'save_failed')
      if (data?.error) throw new Error(data.error.message ?? 'save_failed')
      return data as { ok: boolean; status: string }
    },
    onSuccess: () => {
      setApiKey('')
      setTestMessage(null)
      void queryClient.invalidateQueries({ queryKey: ['tenant-secrets', tenantId] })
      toast({
        description: t(
          'settings.saved_pending',
          "Clau desada com a candidata. Prem «Provar clau» per activar-la.",
        ),
      })
    },
    onError: (err: Error) => {
      toast({ variant: 'destructive', description: err.message })
    },
  })

  const testMutation = useMutation({
    mutationFn: async () => {
      if (!tenantId) throw new Error('missing_tenant')
      const { data, error } = await supabase.functions.invoke('test-map-api-key', {
        headers: { 'x-tenant-id': tenantId },
        body: { keyType },
      })
      if (error) throw new Error((await getFunctionErrorMessage(error)) ?? 'test_failed')
      return data as { ok: boolean; message: string; status: string; latencyMs?: number }
    },
    onSuccess: (data) => {
      setTestMessage(data.message)
      void queryClient.invalidateQueries({ queryKey: ['tenant-secrets', tenantId] })
      toast({
        variant: data.ok ? 'default' : 'destructive',
        description: data.message,
      })
    },
    onError: (err: Error) => {
      toast({ variant: 'destructive', description: err.message })
    },
  })

  const clearMutation = useMutation({
    mutationFn: async () => {
      if (!tenantId) throw new Error('missing_tenant')
      const { data, error } = await supabase.rpc('clear_tenant_map_api_key', {
        p_tenant_id: tenantId,
        p_key_type: keyType,
      })
      if (error) throw error
      return data as { ok?: boolean; status?: string }
    },
    onSuccess: () => {
      setApiKey('')
      setTestMessage(null)
      void queryClient.invalidateQueries({ queryKey: ['tenant-secrets', tenantId] })
      toast({
        description: t(
          'settings.cleared',
          keyType === 'geocoding'
            ? 'Clau esborrada. La cerca usa OpenStreetMap (Nominatim).'
            : keyType === 'maps_js'
              ? 'Clau Maps JS esborrada. El mapa visual no està disponible.'
              : 'Clau Routes esborrada. Les distàncies tornen a haversine.',
        ),
      })
    },
    onError: (err: Error) => {
      toast({ variant: 'destructive', description: err.message })
    },
  })

  const activeUpdated = formatUpdatedAt(secret.active?.updated_at, i18n.language)
  const statusLabel = secret.pending?.rotation_status === 'failed'
    ? t(
        'settings.status_failed',
        'Candidata fallida — desa’n una de nova o torna a provar{{activeHint}}',
        {
          activeHint: secret.active
            ? t('settings.status_active_still', ' (la clau anterior segueix activa)')
            : '',
        },
      )
    : secret.pending
      ? t(
          'settings.status_pending',
          'Candidata pendent de verificació{{activeHint}}',
          {
            activeHint: secret.active
              ? t(
                  'settings.status_active_until_verified',
                  ' — la clau anterior segueix activa fins a provar la nova',
                )
              : '',
          },
        )
      : secret.active
        ? t('settings.status_configured', 'Configurada{{date}}', {
            date: activeUpdated ? ` (${activeUpdated})` : '',
          })
        : statusNone

  const showConfiguredIcon = Boolean(secret.active && !secret.pending)
  const canClear = Boolean(secret.active || secret.pending)

  return (
    <section className="rounded-lg border border-border bg-card p-5 space-y-4">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h3 className="text-sm font-medium text-foreground">{title}</h3>
          <p className="mt-1 text-xs text-muted-foreground flex items-center gap-1.5">
            {showConfiguredIcon ? <CheckCircle2 className="h-3.5 w-3.5 text-emerald-600" /> : null}
            {statusLabel}
          </p>
        </div>
      </div>

      <div className="space-y-1.5">
        <label className="text-xs font-medium text-foreground">
          {t('settings.api_key_label', 'API key')}
        </label>
        <Input
          type="password"
          autoComplete="off"
          value={apiKey}
          onChange={(e) => setApiKey(e.target.value)}
          placeholder={t('settings.api_key_placeholder', 'Enganxa la clau de Google Cloud')}
          disabled={saveMutation.isPending}
        />
      </div>

      <div className="flex flex-wrap gap-2">
        <Button
          type="button"
          size="sm"
          onClick={() => saveMutation.mutate()}
          disabled={saveMutation.isPending || !apiKey.trim()}
        >
          <Save className="h-4 w-4 mr-1.5" />
          {saveMutation.isPending
            ? t('settings.saving', 'Desant…')
            : t('settings.save', 'Desar')}
        </Button>
        <Button
          type="button"
          size="sm"
          variant="outline"
          onClick={() => testMutation.mutate()}
          disabled={testMutation.isPending || !secret.pending}
        >
          {testMutation.isPending
            ? t('settings.testing', 'Provant…')
            : t('settings.test', 'Provar clau')}
        </Button>
        <Button
          type="button"
          size="sm"
          variant="outline"
          onClick={() => {
            if (
              !window.confirm(
                t(
                  'settings.clear_confirm',
                  'Vols esborrar aquesta clau? La cerca tornarà a OpenStreetMap / Nominatim.',
                ),
              )
            ) {
              return
            }
            clearMutation.mutate()
          }}
          disabled={clearMutation.isPending || !canClear}
        >
          <Trash2 className="h-4 w-4 mr-1.5" />
          {clearMutation.isPending
            ? t('settings.clearing', 'Esborrant…')
            : t('settings.clear', 'Esborrar clau')}
        </Button>
      </div>

      {testMessage ? <p className="text-xs text-muted-foreground">{testMessage}</p> : null}

      <div className="rounded-md bg-muted/50 p-3 text-xs text-muted-foreground space-y-1">
        <p className="font-medium text-foreground">
          {t('settings.guide_title', 'Com configurar-ho a Google Cloud')}
        </p>
        <ol className="list-decimal pl-4 space-y-0.5">
          <li>{guide1}</li>
          <li>{guide2}</li>
          <li>{t('settings.guide_3', 'Configura un budget alert (és una alerta, no un tall dur).')}</li>
        </ol>
        <a
          className="inline-block text-primary underline underline-offset-2"
          href="https://console.cloud.google.com/google/maps-apis"
          target="_blank"
          rel="noreferrer"
        >
          {t('settings.guide_link', 'Obrir Google Cloud Console')}
        </a>
      </div>
    </section>
  )
}

function MapsProviderPreferenceCard() {
  const { t } = useTranslation('maps')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id ?? null
  const { data: effective } = useEffectiveSettings({ tenantId })
  const mutation = useTenantSettingsMutation()

  const mapsSettings = parseMapsSettings(effective?.maps)
  const current = mapsSettings.provider

  function setProvider(next: MapsProviderPreference) {
    mutation.mutate(
      {
        maps: {
          provider: next,
          ...(mapsSettings.mapId ? { map_id: mapsSettings.mapId } : {}),
        },
      },
      {
        onSuccess: () => {
          toast({
            description:
              next === 'openstreetmap'
                ? t(
                    'settings.provider_saved_osm',
                    'Preferència: OpenStreetMap (Nominatim + mapa OSM).',
                  )
                : t(
                    'settings.provider_saved_google',
                    'Preferència: Google (geocoding BYOK quan hi hagi clau).',
                  ),
          })
        },
        onError: (err: Error) => {
          toast({ variant: 'destructive', description: err.message })
        },
      },
    )
  }

  return (
    <section className="rounded-lg border border-border bg-card p-5 space-y-3">
      <div>
        <h3 className="text-sm font-medium text-foreground">
          {t('settings.provider_title', 'Proveïdor de mapes')}
        </h3>
        <p className="mt-1 text-xs text-muted-foreground">
          {t(
            'settings.provider_hint',
            'Escull OpenStreetMap (gratuito) o Google Maps per a la cerca d’adreces. El mapa visual usa tiles OSM/Leaflet (no facturem tiles de Google).',
          )}
        </p>
      </div>

      <div className="flex flex-wrap gap-2">
        <Button
          type="button"
          size="sm"
          variant={current === 'openstreetmap' ? 'default' : 'outline'}
          disabled={mutation.isPending}
          onClick={() => setProvider('openstreetmap')}
        >
          {t('settings.provider_osm', 'OpenStreetMap')}
        </Button>
        <Button
          type="button"
          size="sm"
          variant={current === 'google' ? 'default' : 'outline'}
          disabled={mutation.isPending}
          onClick={() => setProvider('google')}
        >
          {t('settings.provider_google', 'Google Maps')}
        </Button>
      </div>
    </section>
  )
}

function MapsUsageSummaryCard({ tenantId }: { tenantId: string }) {
  const { t } = useTranslation('maps')

  const usageQuery = useQuery({
    queryKey: ['geocoding-usage-summary', tenantId],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_tenant_geocoding_usage_summary', {
        p_tenant_id: tenantId,
      })
      if (error) throw error
      return data as {
        usage_month?: string
        today_blocked_requests?: number
        cache_hits?: number
        providers?: Array<{
          provider_key: string
          total_requests: number
          successful_requests: number
          blocked_requests: number
          billable_units: number
          cost_amount: number | string
          mode: string
        }>
      }
    },
  })

  const providers = usageQuery.data?.providers ?? []
  const totalRequests = providers.reduce((s, p) => s + Number(p.total_requests ?? 0), 0)
  const totalBlocked = providers.reduce((s, p) => s + Number(p.blocked_requests ?? 0), 0)
  const cacheHits = Number(usageQuery.data?.cache_hits ?? 0)
  const platformCost = providers
    .filter((p) => p.mode === 'platform')
    .reduce((s, p) => s + Number(p.cost_amount ?? 0), 0)

  return (
    <section className="rounded-lg border border-border bg-card p-5 space-y-3">
      <div>
        <h3 className="text-sm font-medium text-foreground">
          {t('settings.usage_title', 'Ús de geocodificació (aquest mes)')}
        </h3>
        <p className="mt-1 text-xs text-muted-foreground">
          {t(
            'settings.usage_hint',
            'Volum de peticions del tenant. Nominatim no factura; el cost estimat només aplica a mode platform (si n’hi ha). Les peticions en cache també compten al volum.',
          )}
        </p>
      </div>

      {usageQuery.isLoading ? (
        <p className="text-xs text-muted-foreground">{t('settings.usage_loading', 'Carregant…')}</p>
      ) : usageQuery.isError ? (
        <p className="text-xs text-destructive">
          {t('settings.usage_error', 'No s\'ha pogut carregar l\'ús.')}
        </p>
      ) : (
        <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
          <div className="rounded-md bg-muted/40 px-3 py-2">
            <p className="text-[11px] text-muted-foreground">
              {t('settings.usage_total', 'Peticions')}
            </p>
            <p className="text-lg font-semibold tabular-nums">{totalRequests}</p>
          </div>
          <div className="rounded-md bg-muted/40 px-3 py-2">
            <p className="text-[11px] text-muted-foreground">
              {t('settings.usage_cache', 'Cache hits')}
            </p>
            <p className="text-lg font-semibold tabular-nums">{cacheHits}</p>
          </div>
          <div className="rounded-md bg-muted/40 px-3 py-2">
            <p className="text-[11px] text-muted-foreground">
              {t('settings.usage_blocked', 'Bloquejades (mes)')}
            </p>
            <p className="text-lg font-semibold tabular-nums">{totalBlocked}</p>
          </div>
          <div className="rounded-md bg-muted/40 px-3 py-2">
            <p className="text-[11px] text-muted-foreground">
              {t('settings.usage_blocked_today', 'Bloquejades (avui)')}
            </p>
            <p className="text-lg font-semibold tabular-nums">
              {usageQuery.data?.today_blocked_requests ?? 0}
            </p>
          </div>
          <div className="rounded-md bg-muted/40 px-3 py-2">
            <p className="text-[11px] text-muted-foreground">
              {t('settings.usage_cost', 'Cost est. platform')}
            </p>
            <p className="text-lg font-semibold tabular-nums">
              {platformCost > 0 ? `${platformCost.toFixed(2)} €` : '—'}
            </p>
          </div>
        </div>
      )}

      {providers.length > 0 && (
        <ul className="text-xs text-muted-foreground space-y-1">
          {providers.map((p) => (
            <li key={p.provider_key}>
              <span className="font-medium text-foreground">{p.provider_key}</span>
              {': '}
              {p.total_requests} {t('settings.usage_reqs', 'peticions')}
              {p.blocked_requests > 0
                ? ` · ${p.blocked_requests} ${t('settings.usage_blocked_short', 'bloquejades')}`
                : ''}
              {p.mode === 'platform' && Number(p.cost_amount) > 0
                ? ` · ${Number(p.cost_amount).toFixed(2)} €`
                : ''}
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

export function MapsSettingsPage() {
  const { t } = useTranslation('maps')
  const { activeTenant, activeRole } = useTenant()
  const tenantId = activeTenant?.id ?? null
  const canManage = activeRole === 'owner' || activeRole === 'manager'

  const secretsQuery = useQuery({
    queryKey: ['tenant-secrets', tenantId, 'maps'],
    enabled: !!tenantId && canManage,
    queryFn: () => listTenantSecrets(tenantId!),
  })

  const geocodingSecret = useMapSecretStatus(secretsQuery.data, 'geocoding_api_key')
  const routesSecret = useMapSecretStatus(secretsQuery.data, 'routes_api_key')
  const mapsJsSecret = useMapSecretStatus(secretsQuery.data, 'maps_js_api_key')

  if (!canManage) {
    return (
      <div className="rounded-lg border border-border bg-card p-6 text-sm text-muted-foreground">
        <ShieldAlert className="mb-2 h-5 w-5" />
        {t('settings.forbidden', 'Només owner o manager poden configurar les claus de mapes.')}
      </div>
    )
  }

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-foreground flex items-center gap-2">
          <MapPin className="h-5 w-5" />
          {t('settings.title', 'Mapes i geocodificació')}
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">
          {t(
            'settings.subtitle',
            'Configura el proveïdor i les claus Google BYOK. Les crides es fan sempre des del servidor; la clau no es mostra mai.',
          )}
        </p>
      </div>

      <MapsProviderPreferenceCard />

      {tenantId ? <MapsUsageSummaryCard tenantId={tenantId} /> : null}

      <MapKeyCard
        keyType="geocoding"
        title={t('settings.geocoding_title', 'Google Geocoding API')}
        statusNone={t('settings.status_none', "Sense clau (s'usa fallback Nominatim)")}
        guide1={t('settings.guide_1', 'Activa Geocoding API al projecte GCP.')}
        guide2={t(
          'settings.guide_2',
          'Crea una API key i restringeix-la per API (Geocoding). La restricció per IP no és viable amb Supabase Edge Functions.',
        )}
        secret={geocodingSecret}
      />

      <div className="space-y-2">
        <div className="flex items-center gap-2 text-sm font-medium text-foreground">
          <Route className="h-4 w-4" />
          {t('settings.routes_section_hint', 'Distàncies per carretera')}
        </div>
        <p className="text-xs text-muted-foreground">
          {t(
            'settings.routes_fallback_hint',
            'Sense clau Routes, les distàncies es calculen en línia recta (haversine) amb indicador visual.',
          )}
        </p>
        <MapKeyCard
          keyType="routes"
          title={t('settings.routes_title', 'Google Routes API')}
          statusNone={t(
            'settings.routes_status_none',
            'Sense clau (s\'usa aproximació haversine)',
          )}
          guide1={t('settings.routes_guide_1', 'Activa Routes API al projecte GCP.')}
          guide2={t(
            'settings.routes_guide_2',
            'Crea una API key i restringeix-la per API (Routes). La restricció per IP no és viable amb Supabase Edge Functions.',
          )}
          secret={routesSecret}
        />
      </div>

      <div className="space-y-2">
        <div className="flex items-center gap-2 text-sm font-medium text-foreground">
          <MapPin className="h-4 w-4" />
          {t('settings.maps_js_section_hint', 'Mapa visual')}
        </div>
        <p className="text-xs text-muted-foreground">
          {t(
            'settings.maps_js_fallback_hint',
            'Sense clau Maps JS, no es mostra el mapa visual. Les adreces i coords segueixen funcionant via geocoding/rutes.',
          )}
        </p>
        <MapKeyCard
          keyType="maps_js"
          title={t('settings.maps_js_title', 'Google Maps JavaScript API')}
          statusNone={t('settings.maps_js_status_none', 'Sense clau (mapa visual no disponible)')}
          guide1={t('settings.maps_js_guide_1', 'Activa Maps JavaScript API al projecte GCP.')}
          guide2={t(
            'settings.maps_js_guide_2',
            'Crea una API key restringida per API (Maps JavaScript) i per HTTP referrers (dominis del tenant portal).',
          )}
          secret={mapsJsSecret}
        />
        {tenantId ? <MapsJsMapIdCard tenantId={tenantId} /> : null}
      </div>
    </div>
  )
}

function MapsJsMapIdCard({ tenantId }: { tenantId: string }) {
  const { t } = useTranslation('maps')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { data: effective } = useEffectiveSettings({ tenantId })
  const mutation = useTenantSettingsMutation()
  const mapsSettings = parseMapsSettings(effective?.maps)
  const [mapIdInput, setMapIdInput] = useState('')
  const [touched, setTouched] = useState(false)

  useEffect(() => {
    if (!touched) {
      setMapIdInput(mapsSettings.mapId ?? '')
    }
  }, [mapsSettings.mapId, touched])

  function invalidateMapsQueries() {
    void queryClient.invalidateQueries({ queryKey: ['effective_settings'] })
    void queryClient.invalidateQueries({ queryKey: ['maps_js_browser_config', tenantId] })
  }

  function saveMapId() {
    const normalized = normalizeMapIdInput(mapIdInput)
    if (mapIdInput.trim() && !normalized) {
      toast({
        variant: 'destructive',
        description: t('settings.map_id_invalid', 'Format de Map ID invàlid'),
      })
      return
    }

    mutation.mutate(
      {
        maps: {
          provider: mapsSettings.provider,
          map_id: normalized,
        },
      },
      {
        onSuccess: () => {
          setTouched(false)
          setMapIdInput(normalized ?? '')
          invalidateMapsQueries()
          toast({
            description: normalized
              ? t('settings.map_id_saved', 'Map ID desat')
              : t('settings.map_id_cleared', 'Map ID esborrat'),
          })
        },
        onError: (err: Error) => {
          toast({ variant: 'destructive', description: err.message })
        },
      },
    )
  }

  return (
    <section className="rounded-lg border border-border bg-card p-5 space-y-4">
      <div>
        <h3 className="text-sm font-medium text-foreground">
          {t('settings.map_id_title', 'Map ID (Google Cloud)')}
        </h3>
        <p className="mt-1 text-xs text-muted-foreground">
          {t(
            'settings.map_id_hint',
            'Necessari per a estils de núvol i Advanced Markers. Ha de ser del mateix projecte GCP que la clau Maps JS. No és secret (es carrega al navegador).',
          )}
        </p>
        {mapsSettings.mapId ? (
          <p className="mt-1 text-xs text-emerald-700 flex items-center gap-1.5">
            <CheckCircle2 className="h-3.5 w-3.5" />
            {t('settings.map_id_configured', 'Configurat')}: {mapsSettings.mapId}
          </p>
        ) : null}
      </div>

      <div className="space-y-1.5">
        <label htmlFor="maps-js-map-id" className="text-xs font-medium text-foreground">
          {t('settings.map_id_label', 'Map ID')}
        </label>
        <Input
          id="maps-js-map-id"
          type="text"
          autoComplete="off"
          value={mapIdInput}
          onChange={(e) => {
            setTouched(true)
            setMapIdInput(e.target.value)
          }}
          placeholder={t('settings.map_id_placeholder', 'El teu Map ID de GCP')}
          disabled={mutation.isPending}
        />
      </div>

      <div className="flex flex-wrap gap-2">
        <Button type="button" size="sm" onClick={saveMapId} disabled={mutation.isPending}>
          <Save className="h-4 w-4 mr-1.5" />
          {mutation.isPending
            ? t('settings.saving', 'Desant…')
            : t('settings.map_id_save', 'Desar Map ID')}
        </Button>
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={mutation.isPending || (!mapIdInput.trim() && !mapsSettings.mapId)}
          onClick={() => {
            setTouched(true)
            setMapIdInput('')
            mutation.mutate(
              { maps: { provider: mapsSettings.provider, map_id: null } },
              {
                onSuccess: () => {
                  setTouched(false)
                  invalidateMapsQueries()
                  toast({ description: t('settings.map_id_cleared', 'Map ID esborrat') })
                },
                onError: (err: Error) => {
                  toast({ variant: 'destructive', description: err.message })
                },
              },
            )
          }}
        >
          <Trash2 className="h-4 w-4 mr-1.5" />
          {t('settings.map_id_clear', 'Esborrar Map ID')}
        </Button>
      </div>

      <div className="rounded-md bg-muted/50 p-3 text-xs text-muted-foreground space-y-1">
        <p className="font-medium text-foreground">
          {t('settings.map_id_guide_title', 'Com obtenir el Map ID a Google Cloud')}
        </p>
        <ol className="list-decimal pl-4 space-y-0.5">
          <li>
            {t(
              'settings.map_id_guide_1',
              'Al mateix projecte GCP on tens la clau Maps JS, obre Maps → Map Management.',
            )}
          </li>
          <li>
            {t(
              'settings.map_id_guide_2',
              'Crea un Map ID de tipus JavaScript (pots associar-hi un estil de mapa).',
            )}
          </li>
          <li>
            {t(
              'settings.map_id_guide_3',
              'Copia el Map ID i enganxa’l aquí. Ha de coincidir amb el projecte de la API key.',
            )}
          </li>
        </ol>
        <a
          className="inline-block text-primary underline underline-offset-2"
          href="https://console.cloud.google.com/google/maps-apis/studio/maps"
          target="_blank"
          rel="noreferrer"
        >
          {t('settings.map_id_guide_link', 'Obrir Map Management (GCP)')}
        </a>
      </div>
    </section>
  )
}
