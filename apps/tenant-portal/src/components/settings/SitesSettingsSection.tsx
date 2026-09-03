import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { useSites } from '../../hooks/useSites'
import type { TenantInfo } from '../../hooks/useTenants'
import type { SiteInfo } from '../../hooks/useSites'
import {
  parseGeoCoordinates,
  buildGeoCoordinates,
  formatAddressLine,
  type GeoCoordinates,
  type StructuredAddress,
} from '../../lib/geo/geoCoordinates'
import {
  CoordinatePicker,
  type CoordinatePoint,
  type CoordinateSelectionContext,
} from '../maps/CoordinatePicker'
import { AddressLocationFields } from '../maps/AddressLocationFields'

interface Props {
  activeTenant: TenantInfo
  userId: string
  sites: SiteInfo[]
}

/** Strips a stray `metadata.geo_coordinates` left over from before geo columns existed. */
function stripLegacyGeoFromMetadata(
  metadata: SiteInfo['metadata'],
): SiteInfo['metadata'] {
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) return metadata
  if (!('geo_coordinates' in metadata)) return metadata
  const { geo_coordinates: _legacyGeo, ...rest } = metadata as Record<string, unknown>
  return (Object.keys(rest).length > 0 ? rest : null) as SiteInfo['metadata']
}

function siteGeo(site: SiteInfo): {
  point: { lat: number; lng: number } | null
  address: StructuredAddress
} {
  const fromColumn = parseGeoCoordinates(site.geo_coordinates)
  if (fromColumn.point) return fromColumn

  // Legacy fallback: some old rows still keep geo_coordinates nested in metadata.
  const metadataRecord = site.metadata as unknown as Record<string, unknown> | null
  const legacy = parseGeoCoordinates(metadataRecord?.geo_coordinates ?? null)
  return legacy
}

function contextToStructuredAddress(
  context: CoordinateSelectionContext | null,
  addressInput: string,
): StructuredAddress {
  const trimmedAddress = addressInput.trim()
  return {
    street: context?.street ?? null,
    street_number: context?.street_number ?? null,
    city: context?.city ?? null,
    province: context?.province ?? null,
    postal_code: context?.postal_code ?? null,
    country_code: context?.country_code ?? null,
    address: trimmedAddress.length > 0 ? trimmedAddress : (context?.address ?? null),
  }
}

function getErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  if (typeof error === 'object' && error !== null && 'message' in error) {
    const maybeMessage = (error as { message?: unknown }).message
    if (typeof maybeMessage === 'string') return maybeMessage
  }
  return ''
}

function mapFriendlyError(error: unknown, t: (k: string, f: string) => string): string {
  const msg = getErrorMessage(error).toLowerCase()

  if (msg.includes('quota_exceeded')) {
    return t(
      'settings.sites.errors.quota_reactivate',
      "No pots reactivar l'element perquè superes el límit del pla",
    )
  }

  return getErrorMessage(error) || t('settings.sites.errors.generic', 'S\'ha produït un error inesperat.')
}

interface SiteWritePayload {
  name: string
  address: string | null
  street: string | null
  street_number: string | null
  city: string | null
  province: string | null
  postal_code: string | null
  country_code: string | null
  geo_coordinates: GeoCoordinates | null
  metadata: SiteInfo['metadata']
}

function buildSiteWritePayload(
  name: string,
  currentMetadata: SiteInfo['metadata'],
  point: CoordinatePoint | null,
  context: CoordinateSelectionContext | null,
  addressInput: string,
): SiteWritePayload {
  const structured = contextToStructuredAddress(context, addressInput)
  const geo_coordinates = point
    ? buildGeoCoordinates(
        point,
        structured,
        context ? { provider: context.provider, source: context.source, providerData: context.providerData } : undefined,
      )
    : null

  return {
    name: name.trim(),
    address: formatAddressLine(structured) || addressInput.trim() || null,
    street: structured.street ?? null,
    street_number: structured.street_number ?? null,
    city: structured.city ?? null,
    province: structured.province ?? null,
    postal_code: structured.postal_code ?? null,
    country_code: structured.country_code ?? null,
    geo_coordinates,
    metadata: stripLegacyGeoFromMetadata(currentMetadata),
  }
}

// ---------------------------------------------------------------------------
// SitesSettingsSection
//
// Gestió de locals/sites des del Tenant Portal (només propietaris globals).
// Mostra la quota d'ús, el llistat de locals actius i permet crear-ne de nous.
// ---------------------------------------------------------------------------
export function SitesSettingsSection({ activeTenant, userId, sites }: Props) {
  const { t } = useTranslation('common')
  const queryClient = useQueryClient()

  const maxSites    = activeTenant.max_sites ?? 1
  const usedSites   = sites.length                        // sites ja és actius-only
  const atQuota     = maxSites > 0 && usedSites >= maxSites
  const quotaPct    = maxSites > 0 ? Math.min((usedSites / maxSites) * 100, 100) : 0

  // ── Create modal state ──────────────────────────────────────────────────
  const [showCreate,    setShowCreate]    = useState(false)
  const [createName,    setCreateName]    = useState('')
  const [createAddress, setCreateAddress] = useState('')
  const [createStructuredAddress, setCreateStructuredAddress] = useState<StructuredAddress>({})
  const [createCoordinates, setCreateCoordinates] = useState<CoordinatePoint | null>(null)
  const [createCoordinateContext, setCreateCoordinateContext] = useState<CoordinateSelectionContext | null>(null)
  const [isArchiveOpen, setIsArchiveOpen] = useState(false)

  // ── Edit inline state ───────────────────────────────────────────────────
  const [editingId,   setEditingId]   = useState<string | null>(null)
  const [editName,    setEditName]    = useState('')
  const [editAddress, setEditAddress] = useState('')
  const [editStructuredAddress, setEditStructuredAddress] = useState<StructuredAddress>({})
  const [editCoordinates, setEditCoordinates] = useState<CoordinatePoint | null>(null)
  const [editCoordinateContext, setEditCoordinateContext] = useState<CoordinateSelectionContext | null>(null)

  const {
    data: inactiveSites = [],
    isLoading: inactiveSitesLoading,
    isError: inactiveSitesError,
    error: inactiveSitesErrorObject,
  } = useSites(activeTenant.id, userId, 'inactive', { enabled: isArchiveOpen })

  // ── Mutations ───────────────────────────────────────────────────────────
  const createMutation = useMutation({
    mutationFn: async (payload: SiteWritePayload) => {
      // `sites` view Insert type is stale (missing street/geo_coordinates columns
      // added in supabase/migrations/20261144000001_maps_geo_coordinates_core.sql).
      const { error } = await supabase.from('sites').insert({
        tenant_id: activeTenant.id,
        ...payload,
      } as any)
      if (error) throw error
    },
    onSuccess: async () => {
      // 1. Refresh JWT so the new site appears in the JWT claims (auth hook)
      await supabase.auth.refreshSession()
      // 2. Invalidate React Query cache so TenantContext re-fetches sites
      await queryClient.invalidateQueries({ queryKey: ['sites', activeTenant.id] })
      setShowCreate(false)
      setCreateName('')
      setCreateAddress('')
      setCreateStructuredAddress({})
      setCreateCoordinates(null)
      setCreateCoordinateContext(null)
    },
  })

  const updateMutation = useMutation({
    mutationFn: async ({
      siteId,
      payload,
    }: {
      siteId: string
      payload: SiteWritePayload
    }) => {
      const { error } = await supabase
        .from('sites')
        .update(payload as any)
        .eq('id', siteId)
      if (error) throw error
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['sites', activeTenant.id] })
      setEditingId(null)
    },
  })

  const deactivateMutation = useMutation({
    mutationFn: async ({ siteId }: { siteId: string }) => {
      const { error } = await supabase.from('sites').update({ is_active: false }).eq('id', siteId)
      if (error) throw error
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['sites', activeTenant.id] })
    },
  })

  const reactivateMutation = useMutation({
    mutationFn: async ({ siteId }: { siteId: string }) => {
      const { error } = await supabase.from('sites').update({ is_active: true }).eq('id', siteId)
      if (error) throw error
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['sites', activeTenant.id] })
    },
  })

  function openCreate() {
    setCreateName('')
    setCreateAddress('')
    setCreateStructuredAddress({})
    setCreateCoordinates(null)
    setCreateCoordinateContext(null)
    createMutation.reset()
    setShowCreate(true)
  }

  function handleCreateSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!createName.trim()) return

    createMutation.mutate(
      buildSiteWritePayload(
        createName,
        null,
        createCoordinates,
        createCoordinateContext,
        createAddress,
      ),
    )
  }

  function startEditing(site: SiteInfo) {
    const geo = siteGeo(site)
    setEditingId(site.id)
    setEditName(site.name)
    setEditAddress(site.address ?? formatAddressLine(geo.address))
    setEditStructuredAddress(geo.address)
    setEditCoordinates(geo.point)
    setEditCoordinateContext(
      geo.point
        ? {
            address: geo.address.address ?? null,
            street: geo.address.street ?? null,
            street_number: geo.address.street_number ?? null,
            city: geo.address.city ?? null,
            province: geo.address.province ?? null,
            postal_code: geo.address.postal_code ?? null,
            country_code: geo.address.country_code ?? null,
            provider: 'manual',
            source: 'manual_input',
          }
        : null,
    )
    updateMutation.reset()
  }

  function handleEditCoordinateContextChange(context: CoordinateSelectionContext | null) {
    setEditCoordinateContext(context)
    if (context) {
      setEditStructuredAddress({
        street: context.street ?? null,
        street_number: context.street_number ?? null,
        city: context.city ?? null,
        province: context.province ?? null,
        postal_code: context.postal_code ?? null,
        country_code: context.country_code ?? null,
        address: context.address ?? null,
      })
      if (context.address) setEditAddress(context.address)
    }
  }

  function handleCreateCoordinateContextChange(context: CoordinateSelectionContext | null) {
    setCreateCoordinateContext(context)
    if (context) {
      setCreateStructuredAddress({
        street: context.street ?? null,
        street_number: context.street_number ?? null,
        city: context.city ?? null,
        province: context.province ?? null,
        postal_code: context.postal_code ?? null,
        country_code: context.country_code ?? null,
        address: context.address ?? null,
      })
      if (context.address) setCreateAddress(context.address)
    }
  }

  function handleEditAddressFieldsChange(next: StructuredAddress) {
    setEditStructuredAddress(next)
    setEditCoordinateContext((prev) => ({
      address: prev?.address ?? null,
      provider: prev?.provider ?? 'manual',
      source: prev?.source ?? 'manual_input',
      providerData: prev?.providerData,
      street: next.street ?? null,
      street_number: next.street_number ?? null,
      city: next.city ?? null,
      province: next.province ?? null,
      postal_code: next.postal_code ?? null,
      country_code: next.country_code ?? null,
    }))
  }

  function handleCreateAddressFieldsChange(next: StructuredAddress) {
    setCreateStructuredAddress(next)
    setCreateCoordinateContext((prev) => ({
      address: prev?.address ?? null,
      provider: prev?.provider ?? 'manual',
      source: prev?.source ?? 'manual_input',
      providerData: prev?.providerData,
      street: next.street ?? null,
      street_number: next.street_number ?? null,
      city: next.city ?? null,
      province: next.province ?? null,
      postal_code: next.postal_code ?? null,
      country_code: next.country_code ?? null,
    }))
  }

  function handleEditSubmit(siteId: string) {
    if (!editName.trim()) return

    const site = sites.find((item) => item.id === siteId)
    if (!site) return

    // Merge manual AddressLocationFields edits with picker context before saving.
    const mergedContext: CoordinateSelectionContext | null = editCoordinateContext
      ? { ...editCoordinateContext, ...editStructuredAddress }
      : null

    updateMutation.mutate({
      siteId,
      payload: buildSiteWritePayload(
        editName,
        site.metadata,
        editCoordinates,
        mergedContext,
        editAddress,
      ),
    })
  }

  return (
    <section
      id="locals"
      aria-labelledby="heading-locals"
      className="rounded-2xl border bg-card p-6 scroll-mt-6 space-y-5"
    >
      {/* Section header */}
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 id="heading-locals" className="text-lg font-semibold text-foreground">
            {t('settings.sections.sites', 'Gestió de Locals')}
          </h2>
          <p className="text-sm text-muted-foreground mt-0.5">
            {t('settings.sites_description', 'Gestiona els locals o seus de la teva franquícia.')}
          </p>
        </div>
        <button
          onClick={openCreate}
          disabled={atQuota}
          title={atQuota ? t('settings.sites_quota_reached', 'Has assolit el límit del teu pla') : undefined}
          className="shrink-0 text-sm px-4 py-2 rounded-lg bg-primary text-primary-foreground font-medium hover:opacity-90 transition disabled:opacity-40 disabled:cursor-not-allowed"
        >
          {t('settings.sites_create', 'Nou Local')}
        </button>
      </div>

      {/* Quota indicator */}
      <div className="space-y-1.5">
        <div className="flex items-center justify-between text-xs text-muted-foreground">
          <span>
            {t('settings.sites_usage', '{{used}} de {{max}} locals en ús', {
              used: usedSites,
              max:  maxSites,
            })}
          </span>
          <span>{activeTenant.plan_display_name ?? activeTenant.plan_name ?? '—'}</span>
        </div>
        <div className="w-full h-1.5 bg-muted rounded-full overflow-hidden">
          <div
            className={`h-full rounded-full transition-all ${
              atQuota ? 'bg-destructive' : 'bg-primary'
            }`}
            style={{ width: `${quotaPct}%` }}
          />
        </div>
        {atQuota && (
          <p className="text-xs text-destructive font-medium">
            {t(
              'settings.sites_quota_message',
              'Has assolit el límit de locals del teu pla. Millora el pla per afegir-ne més.',
            )}
          </p>
        )}
      </div>

      {/* Sites list */}
      {sites.length === 0 ? (
        <div className="rounded-xl border-2 border-dashed border-border p-8 text-center">
          <p className="text-sm text-muted-foreground">
            {t('settings.sites_empty', 'Encara no tens cap local configurat.')}
          </p>
        </div>
      ) : (
        <ul className="divide-y divide-border rounded-xl border overflow-hidden">
          {sites.map((site) => {
            const geo = siteGeo(site)
            return (
            <li key={site.id} className="bg-card">
              {editingId === site.id ? (
                /* ── Edit row ── */
                <div className="px-4 py-3 space-y-3">
                  <input
                    autoFocus
                    type="text"
                    value={editName}
                    onChange={(e) => setEditName(e.target.value)}
                    placeholder={t('settings.sites_name_placeholder', 'Nom del local')}
                    className="w-full text-sm rounded-lg border border-input bg-background px-3 py-2 focus:outline-none focus:ring-2 focus:ring-ring"
                  />
                  <input
                    type="text"
                    value={editAddress}
                    onChange={(e) => setEditAddress(e.target.value)}
                    placeholder={t('settings.sites_address_placeholder', 'Adreça (opcional)')}
                    className="w-full text-sm rounded-lg border border-input bg-background px-3 py-2 focus:outline-none focus:ring-2 focus:ring-ring"
                  />
                  <AddressLocationFields
                    value={editStructuredAddress}
                    onChange={handleEditAddressFieldsChange}
                    disabled={updateMutation.isPending}
                  />
                  <CoordinatePicker
                    value={editCoordinates}
                    onChange={setEditCoordinates}
                    onContextChange={handleEditCoordinateContextChange}
                    disabled={updateMutation.isPending}
                    showHeader={false}
                  />
                  {updateMutation.isError && (
                    <p className="text-xs text-destructive">
                      {updateMutation.error instanceof Error
                        ? updateMutation.error.message
                        : t('settings.sites_update_error', 'Error en desar els canvis.')}
                    </p>
                  )}
                  <div className="flex gap-2 justify-end pt-1">
                    <button
                      onClick={() => setEditingId(null)}
                      disabled={updateMutation.isPending}
                      className="text-xs px-3 py-1.5 rounded-lg border border-border text-muted-foreground hover:bg-accent transition"
                    >
                      {t('common.cancel', 'Cancel·lar')}
                    </button>
                    <button
                      onClick={() => handleEditSubmit(site.id)}
                      disabled={updateMutation.isPending || !editName.trim()}
                      className="text-xs px-3 py-1.5 rounded-lg bg-primary text-primary-foreground font-medium hover:opacity-90 disabled:opacity-50 transition"
                    >
                      {updateMutation.isPending
                        ? t('common.saving', 'Desant…')
                        : t('common.save', 'Desar')}
                    </button>
                  </div>
                </div>
              ) : (
                /* ── Normal row ── */
                <div className="flex items-center justify-between px-4 py-3 gap-3">
                  <div className="min-w-0">
                    <p className="text-sm font-medium text-foreground truncate">{site.name}</p>
                    {site.address && (
                      <p className="text-xs text-muted-foreground truncate mt-0.5">{site.address}</p>
                    )}
                    {geo.point && (
                      <p className="text-xs text-muted-foreground truncate mt-0.5">
                        {t('settings.sites_coordinates_label', 'GPS: {{lat}}, {{lng}}', {
                          lat: geo.point.lat.toFixed(6),
                          lng: geo.point.lng.toFixed(6),
                        })}
                      </p>
                    )}
                  </div>
                  <div className="flex items-center gap-2 shrink-0">
                    <button
                      onClick={() =>
                        deactivateMutation.mutate({ siteId: site.id })
                      }
                      className="text-xs px-3 py-1.5 rounded-lg border border-border text-muted-foreground hover:bg-accent transition"
                    >
                      {t('settings.sites.deactivate', 'Desactivar')}
                    </button>
                    <button
                      onClick={() => startEditing(site)}
                      className="text-xs px-3 py-1.5 rounded-lg border border-border text-muted-foreground hover:bg-accent transition"
                    >
                      {t('common.edit', 'Editar')}
                    </button>
                  </div>
                </div>
              )}
            </li>
            )
          })}
        </ul>
      )}

      {(createMutation.isError || updateMutation.isError || deactivateMutation.isError || reactivateMutation.isError) && (
        <div className="rounded-lg bg-destructive/10 border border-destructive/30 px-4 py-3 text-sm text-destructive">
          {mapFriendlyError(
            createMutation.error ??
              updateMutation.error ??
              deactivateMutation.error ??
              reactivateMutation.error,
            t,
          )}
        </div>
      )}

      <div className="border-t pt-4">
        <button
          onClick={() => setIsArchiveOpen((v) => !v)}
          className="text-sm font-medium text-foreground hover:underline"
        >
          {isArchiveOpen
            ? t('settings.sites.archive.hide', 'Amagar arxiu de locals inactius')
            : t('settings.sites.archive.show', 'Mostrar arxiu de locals inactius')}
        </button>

        {isArchiveOpen && (
          <div className="mt-3">
            {inactiveSitesLoading ? (
              <div className="rounded-xl border p-4 text-sm text-muted-foreground">
                {t('settings.sites.archive.loading', 'Carregant arxiu...')}
              </div>
            ) : inactiveSitesError ? (
              <div className="rounded-lg bg-destructive/10 border border-destructive/30 px-4 py-3 text-sm text-destructive">
                {mapFriendlyError(inactiveSitesErrorObject, t)}
              </div>
            ) : inactiveSites.length === 0 ? (
              <div className="rounded-xl border-2 border-dashed border-border p-6 text-center text-sm text-muted-foreground">
                {t('settings.sites.archive.empty', 'No hi ha locals inactius a l\'arxiu.')}
              </div>
            ) : (
              <ul className="divide-y divide-border rounded-xl border overflow-hidden">
                {inactiveSites.map((site) => (
                  <li key={site.id} className="bg-card px-4 py-3 flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="text-sm font-medium text-foreground truncate">{site.name}</p>
                      {site.address && (
                        <p className="text-xs text-muted-foreground truncate mt-0.5">{site.address}</p>
                      )}
                    </div>
                    <button
                      onClick={() => reactivateMutation.mutate({ siteId: site.id })}
                      className="shrink-0 text-xs px-3 py-1.5 rounded-lg bg-primary text-primary-foreground hover:opacity-90 transition"
                    >
                      {t('settings.sites.reactivate', 'Reactivar')}
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}
      </div>

      {/* ── Create modal ──────────────────────────────────────────────────── */}
      {showCreate && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
          <div className="bg-card rounded-2xl shadow-xl border border-border w-full max-w-md p-6 space-y-5 max-h-[90vh] overflow-y-auto">
            <h3 className="text-lg font-semibold text-foreground">
              {t('settings.sites_create_title', 'Nou Local')}
            </h3>

            <form onSubmit={handleCreateSubmit} className="space-y-4">
              {createMutation.isError && (
                <div className="rounded-lg bg-destructive/10 border border-destructive/30 px-4 py-3 text-sm text-destructive">
                  {mapFriendlyError(createMutation.error, t)}
                </div>
              )}

              <div className="space-y-1.5">
                <label className="block text-sm font-medium text-foreground">
                  {t('settings.sites_name', 'Nom del local')}{' '}
                  <span className="text-destructive">*</span>
                </label>
                <input
                  autoFocus
                  type="text"
                  value={createName}
                  onChange={(e) => setCreateName(e.target.value)}
                  placeholder={t('settings.sites_name_placeholder', 'Ex: Local Eixample')}
                  disabled={createMutation.isPending}
                  className="w-full text-sm rounded-lg border border-input bg-background px-3 py-2 focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
                />
              </div>

              <div className="space-y-1.5">
                <label className="block text-sm font-medium text-foreground">
                  {t('settings.sites_address', 'Adreça')}{' '}
                  <span className="text-muted-foreground text-xs">
                    ({t('common.optional', 'opcional')})
                  </span>
                </label>
                <input
                  type="text"
                  value={createAddress}
                  onChange={(e) => setCreateAddress(e.target.value)}
                  placeholder={t(
                    'settings.sites_address_placeholder',
                    'Ex: Carrer Major, 1, 08001 Barcelona',
                  )}
                  disabled={createMutation.isPending}
                  className="w-full text-sm rounded-lg border border-input bg-background px-3 py-2 focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
                />
              </div>

              <AddressLocationFields
                value={createStructuredAddress}
                onChange={handleCreateAddressFieldsChange}
                disabled={createMutation.isPending}
              />

              <div className="space-y-1.5">
                <label className="block text-sm font-medium text-foreground">
                  {t('settings.sites_coordinates_title', 'Coordenades')}{' '}
                  <span className="text-muted-foreground text-xs">
                    ({t('common.optional', 'opcional')})
                  </span>
                </label>
                <CoordinatePicker
                  value={createCoordinates}
                  onChange={setCreateCoordinates}
                  onContextChange={handleCreateCoordinateContextChange}
                  disabled={createMutation.isPending}
                  showHeader={false}
                />
              </div>

              <div className="flex justify-end gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setShowCreate(false)}
                  disabled={createMutation.isPending}
                  className="text-sm px-4 py-2 rounded-lg border border-border text-muted-foreground hover:bg-accent transition"
                >
                  {t('common.cancel', 'Cancel·lar')}
                </button>
                <button
                  type="submit"
                  disabled={createMutation.isPending || !createName.trim()}
                  className="text-sm px-4 py-2 rounded-lg bg-primary text-primary-foreground font-medium hover:opacity-90 disabled:opacity-50 transition"
                >
                  {createMutation.isPending
                    ? t('settings.sites_creating', 'Creant…')
                    : t('settings.sites_create_confirm', 'Crear local')}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </section>
  )
}
