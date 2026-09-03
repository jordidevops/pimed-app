import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { useSites } from '@/hooks/useSites'
import { getAncestors, getLocations } from '@/features/locations/api/locationsService'
import { generatePortalQrDataUrl } from '@/features/employee-portal/utils/portalQrGenerate'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import {
  useAttendanceStations,
  useBulkRevokeAttendanceStationSecrets,
  useBulkUpdateAttendanceStationOps,
  useCreateStationPairingCode,
  useRevokeStationSecret,
  useStationFleetHealth,
  useUpdateAttendanceStation,
} from '../api/useAttendanceStations'
import type { AttendanceStationRow } from '../api/attendanceStationsService'
import type { Location } from '@/features/locations/api/locationsService'
import { StationAdminAuditDrawer } from '../components/StationAdminAuditDrawer'
import { StationBrandingFields } from '../components/StationBrandingFields'
import { StationFleetHealthPanel } from '../components/StationFleetHealthPanel'
import { StationHistoryDrawer } from '../components/StationHistoryDrawer'
import {
  STATION_UX_PRESET_OPTIONS,
  type StationUxPreset,
} from '../config/stationUxPresets'

function extractLatLng(geo: Location['geo_coordinates']): { lat: number; lng: number } | null {
  if (!geo || typeof geo !== 'object' || Array.isArray(geo)) return null
  const obj = geo as Record<string, unknown>
  const lat = Number(obj.lat ?? obj.latitude)
  const lng = Number(obj.lng ?? obj.lon ?? obj.long ?? obj.longitude)
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null
  return { lat, lng }
}

const selectClassName =
  'w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring'

function statusBadge(status: string | null | undefined) {
  switch (status) {
    case 'active':
      return <Badge variant="default">Activa</Badge>
    case 'pending':
      return <Badge variant="secondary">Pendent</Badge>
    case 'suspended':
      return <Badge variant="outline">Suspesa</Badge>
    case 'retired':
      return <Badge variant="destructive">Baixa</Badge>
    default:
      return <Badge variant="outline">{status ?? '—'}</Badge>
  }
}

function connectivityBadge(status: string | null | undefined) {
  switch (status) {
    case 'online':
      return <Badge variant="default">En línia</Badge>
    case 'stale':
      return <Badge variant="secondary">Inactiva</Badge>
    case 'offline':
      return <Badge variant="destructive">Sense connexió</Badge>
    case 'never_seen':
      return <Badge variant="outline">Mai connectada</Badge>
    case 'inactive':
      return <Badge variant="outline">No operativa</Badge>
    default:
      return <Badge variant="outline">{status ?? '—'}</Badge>
  }
}

export function AttendanceStationsPage() {
  const { t } = useTranslation('settings')
  const { user } = useAuth()
  const { activeTenant, activeRole } = useTenant()
  const canManage = activeRole === 'owner' || activeRole === 'manager'
  const tenantId = activeTenant?.id ?? null

  const { data: stations = [], isLoading, error } = useAttendanceStations()
  const { data: fleetHealth, isLoading: fleetLoading } = useStationFleetHealth(tenantId)
  const { data: sites = [] } = useSites(tenantId, user?.id, 'active')
  const createPairing = useCreateStationPairingCode()
  const updateStation = useUpdateAttendanceStation()
  const bulkOps = useBulkUpdateAttendanceStationOps()
  const bulkRevoke = useBulkRevokeAttendanceStationSecrets()
  const revokeSecret = useRevokeStationSecret()

  const [filterSiteId, setFilterSiteId] = useState('')
  const [filterStatus, setFilterStatus] = useState('')
  const [filterConnectivity, setFilterConnectivity] = useState('')
  const [selectedIds, setSelectedIds] = useState<string[]>([])

  const [pairOpen, setPairOpen] = useState(false)
  const [pairSiteId, setPairSiteId] = useState<string>('')
  const [pairLocationId, setPairLocationId] = useState<string>('')
  const [pairResult, setPairResult] = useState<{ code: string; expires_at: string } | null>(null)
  const [pairQrDataUrl, setPairQrDataUrl] = useState<string | null>(null)

  const [editOpen, setEditOpen] = useState(false)
  const [editStation, setEditStation] = useState<AttendanceStationRow | null>(null)
  const [editName, setEditName] = useState('')
  const [editSiteId, setEditSiteId] = useState('')
  const [editLocationId, setEditLocationId] = useState('')
  const [editStatus, setEditStatus] = useState('pending')
  const [editAllowedManual, setEditAllowedManual] = useState(true)
  const [editAllowedQr, setEditAllowedQr] = useState(false)
  const [editGeoAntifraudEnabled, setEditGeoAntifraudEnabled] = useState(false)
  const [editGeoAntifraudRadiusM, setEditGeoAntifraudRadiusM] = useState(150)
  const [editWarnWrongScheduledLocation, setEditWarnWrongScheduledLocation] = useState(true)
  const [editBlockWrongScheduledLocation, setEditBlockWrongScheduledLocation] = useState(false)
  const [editAllowUnassignedPunch, setEditAllowUnassignedPunch] = useState(true)
  const [editWarnUnassignedPunch, setEditWarnUnassignedPunch] = useState(true)
  const [editDisplayTitle, setEditDisplayTitle] = useState('')
  const [editDisplayLogoUrl, setEditDisplayLogoUrl] = useState('')
  const [editEntryMode, setEditEntryMode] = useState('employee_list')
  const [editListLayout, setEditListLayout] = useState('compact')
  const [editDocumentMatch, setEditDocumentMatch] = useState('suffix')
  const [editDocumentSuffixLength, setEditDocumentSuffixLength] = useState(4)
  const [editIdentityConfirm, setEditIdentityConfirm] = useState('none')
  const [editQrIdentityConfirm, setEditQrIdentityConfirm] = useState('none')
  const [editSessionIdleSeconds, setEditSessionIdleSeconds] = useState(60)
  const [editSessionCountdownSeconds, setEditSessionCountdownSeconds] = useState(15)
  const [editSessionAllowHistory, setEditSessionAllowHistory] = useState(false)
  const [editSessionHistoryMaxDays, setEditSessionHistoryMaxDays] = useState(90)
  const [editUxPreset, setEditUxPreset] = useState<StationUxPreset>('custom')
  const [editWaitingIdleSeconds, setEditWaitingIdleSeconds] = useState(0)
  const [editMaskNamesOnWaiting, setEditMaskNamesOnWaiting] = useState(false)

  const [historyStation, setHistoryStation] = useState<AttendanceStationRow | null>(null)
  const [historyOpen, setHistoryOpen] = useState(false)
  const [auditStation, setAuditStation] = useState<AttendanceStationRow | null>(null)
  const [auditOpen, setAuditOpen] = useState(false)

  const { data: pairLocations = [] } = useQuery({
    queryKey: ['locations', 'pair', pairSiteId],
    queryFn: () => getLocations(pairSiteId),
    enabled: !!pairSiteId,
  })
  const { data: editLocations = [] } = useQuery({
    queryKey: ['locations', 'edit', editSiteId],
    queryFn: () => getLocations(editSiteId),
    enabled: !!editSiteId,
  })

  const siteNameById = useMemo(
    () => new Map(sites.map((s) => [s.id, s.name])),
    [sites],
  )

  const filteredStations = useMemo(() => {
    return stations.filter((station) => {
      if (filterSiteId && station.site_id !== filterSiteId) return false
      if (filterStatus && station.status !== filterStatus) return false
      if (filterConnectivity && station.connectivity_status !== filterConnectivity) return false
      return true
    })
  }, [stations, filterSiteId, filterStatus, filterConnectivity])

  function toggleSelected(id: string) {
    setSelectedIds((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]))
  }

  function toggleSelectAllFiltered() {
    const ids = filteredStations.map((s) => s.id).filter(Boolean) as string[]
    const allSelected = ids.length > 0 && ids.every((id) => selectedIds.includes(id))
    setSelectedIds(allSelected ? [] : ids)
  }

  async function runBulkStatus(status: string) {
    if (selectedIds.length === 0) return
    await bulkOps.mutateAsync({ deviceIds: selectedIds, status })
    setSelectedIds([])
  }

  async function runBulkLockdown(lock: boolean) {
    if (selectedIds.length === 0) return
    await bulkOps.mutateAsync({ deviceIds: selectedIds, opsLockdown: lock })
    setSelectedIds([])
  }

  async function runBulkRevoke() {
    if (selectedIds.length === 0) return
    if (!window.confirm(t('attendance_stations.bulk_revoke_confirm', 'Revocar secrets de les estacions seleccionades?'))) {
      return
    }
    await bulkRevoke.mutateAsync(selectedIds)
    setSelectedIds([])
  }

  const editLocationHasGeo = useMemo(() => {
    if (!editLocationId) return false
    const location = editLocations.find((loc) => loc.id === editLocationId)
    return extractLatLng(location?.geo_coordinates ?? null) !== null
  }, [editLocationId, editLocations])

  function openEdit(station: AttendanceStationRow) {
    setEditStation(station)
    setEditName(station.name ?? '')
    setEditSiteId(station.site_id ?? '')
    setEditLocationId(station.location_id ?? '')
    setEditStatus(station.status ?? 'pending')
    const methods = station.allowed_methods ?? ['manual']
    setEditAllowedManual(methods.includes('manual'))
    setEditAllowedQr(methods.includes('qr'))
    setEditGeoAntifraudEnabled(Boolean(station.geo_antifraud_enabled))
    setEditGeoAntifraudRadiusM(station.geo_antifraud_radius_m ?? 150)
    setEditWarnWrongScheduledLocation(station.warn_wrong_scheduled_location ?? true)
    setEditBlockWrongScheduledLocation(Boolean(station.block_wrong_scheduled_location))
    setEditAllowUnassignedPunch(station.allow_unassigned_punch ?? true)
    setEditWarnUnassignedPunch(station.warn_unassigned_punch ?? true)
    setEditDisplayTitle(station.display_title ?? '')
    setEditDisplayLogoUrl(station.display_logo_url ?? '')
    setEditEntryMode(station.entry_mode ?? 'employee_list')
    setEditListLayout(station.employee_list_layout ?? 'compact')
    setEditDocumentMatch(station.document_match ?? 'suffix')
    setEditDocumentSuffixLength(station.document_suffix_length ?? 4)
    setEditIdentityConfirm(station.identity_confirm ?? 'none')
    setEditQrIdentityConfirm(station.qr_identity_confirm ?? 'none')
    setEditSessionIdleSeconds(station.session_idle_seconds ?? 60)
    setEditSessionCountdownSeconds(station.session_return_countdown_seconds ?? 15)
    setEditSessionAllowHistory(station.session_allow_history ?? false)
    setEditSessionHistoryMaxDays(station.session_history_max_days ?? 90)
    setEditUxPreset((station.ux_preset as StationUxPreset) ?? 'custom')
    setEditWaitingIdleSeconds(station.waiting_idle_seconds ?? 0)
    setEditMaskNamesOnWaiting(station.mask_names_on_waiting ?? false)
    setEditOpen(true)
  }

  async function handleCreatePairing() {
    const result = await createPairing.mutateAsync({
      siteId: pairSiteId || null,
      locationId: pairLocationId || null,
    })
    setPairResult({ code: result.code, expires_at: result.expires_at })
    setPairQrDataUrl(null)
    try {
      const qr = await generatePortalQrDataUrl(result.code, 280)
      setPairQrDataUrl(qr)
    } catch {
      setPairQrDataUrl(null)
    }
  }

  function openHistory(station: AttendanceStationRow) {
    setHistoryStation(station)
    setHistoryOpen(true)
  }

  function openAudit(station: AttendanceStationRow) {
    setAuditStation(station)
    setAuditOpen(true)
  }

  async function handleSaveEdit() {
    if (!editStation?.id) return
    const allowedMethods: string[] = []
    if (editAllowedManual) allowedMethods.push('manual')
    if (editAllowedQr) allowedMethods.push('qr')
    if (allowedMethods.length === 0) {
      window.alert('Selecciona almenys un mètode de fitxatge (manual o QR).')
      return
    }
    if (editGeoAntifraudEnabled && !editLocationHasGeo) {
      window.alert('La ubicació seleccionada no té coordenades GPS. Defineix-les a /locations abans d\'activar la validació geo.')
      return
    }
    if (editGeoAntifraudRadiusM < 25 || editGeoAntifraudRadiusM > 2000) {
      window.alert('El radi de validació ha d\'estar entre 25 i 2000 metres.')
      return
    }
    if (editDocumentSuffixLength < 3 || editDocumentSuffixLength > 8) {
      window.alert('La longitud mínima del sufix ha d\'estar entre 3 i 8.')
      return
    }
    if (editSessionIdleSeconds < 15 || editSessionIdleSeconds > 600) {
      window.alert('El temps d\'inactivitat ha d\'estar entre 15 i 600 segons.')
      return
    }
    if (editSessionCountdownSeconds < 5 || editSessionCountdownSeconds > 120) {
      window.alert('El countdown de retorn ha d\'estar entre 5 i 120 segons.')
      return
    }
    if (editSessionAllowHistory && (editSessionHistoryMaxDays < 1 || editSessionHistoryMaxDays > 90)) {
      window.alert('El rang màxim d\'historial ha d\'estar entre 1 i 90 dies.')
      return
    }
    await updateStation.mutateAsync({
      deviceId: editStation.id,
      name: editName,
      siteId: editSiteId || null,
      locationId: editLocationId || null,
      status: editStatus,
      allowedMethods,
      geoAntifraudEnabled: editGeoAntifraudEnabled,
      geoAntifraudRadiusM: editGeoAntifraudRadiusM,
      warnWrongScheduledLocation: editWarnWrongScheduledLocation,
      blockWrongScheduledLocation: editBlockWrongScheduledLocation,
      allowUnassignedPunch: editAllowUnassignedPunch,
      warnUnassignedPunch: editWarnUnassignedPunch,
      displayTitle: editDisplayTitle,
      displayLogoUrl: editDisplayLogoUrl,
      entryMode: editEntryMode,
      employeeListLayout: editListLayout,
      documentMatch: editDocumentMatch,
      documentSuffixLength: editDocumentSuffixLength,
      identityConfirm: editIdentityConfirm,
      qrIdentityConfirm: editQrIdentityConfirm,
      sessionIdleSeconds: editSessionIdleSeconds,
      sessionReturnCountdownSeconds: editSessionCountdownSeconds,
      sessionAllowHistory: editSessionAllowHistory,
      sessionHistoryMaxDays: editSessionHistoryMaxDays,
      uxPreset: editUxPreset,
      waitingIdleSeconds: editWaitingIdleSeconds,
      maskNamesOnWaiting: editMaskNamesOnWaiting,
    })
    setEditOpen(false)
  }

  if (!activeTenant) return null

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold text-foreground">
            {t('attendance_stations.title', 'Estacions de fitxatge')}
          </h2>
          <p className="mt-0.5 text-sm text-muted-foreground max-w-2xl">
            {t(
              'attendance_stations.description',
              'Tablets i terminals fixos vinculats a ubicacions de l\'empresa. Cada fitxatge registra on ha treballat l\'empleat (sense GPS al tablet).',
            )}
          </p>
        </div>
        {canManage && (
          <Button
            onClick={() => {
              setPairResult(null)
              setPairQrDataUrl(null)
              setPairSiteId('')
              setPairLocationId('')
              setPairOpen(true)
            }}
          >
            {t('attendance_stations.new_pairing', 'Generar codi d\'aparellament')}
          </Button>
        )}
      </div>

      <p className="text-sm text-muted-foreground">
        {t('attendance_stations.locations_hint', 'Gestiona les ubicacions a')}{' '}
        <Link to="/locations" className="text-primary underline">
          /locations
        </Link>
        . {t('attendance_stations.station_ui_hint', 'Obre la UI estació a')}{' '}
        <code className="rounded bg-muted px-1 py-0.5 text-xs">/station</code>{' '}
        {t('attendance_stations.station_ui_hint2', 'al public-portal.')}
      </p>

      <StationFleetHealthPanel
        health={fleetHealth}
        isLoading={fleetLoading}
        onFilterConnectivity={(status) => setFilterConnectivity(status)}
      />

      <div className="flex flex-wrap gap-2">
        <select
          value={filterSiteId}
          onChange={(e) => setFilterSiteId(e.target.value)}
          className={selectClassName + ' max-w-[12rem]'}
        >
          <option value="">{t('attendance_stations.filter_all_sites', 'Tots els centres')}</option>
          {sites.map((site) => (
            <option key={site.id} value={site.id}>{site.name}</option>
          ))}
        </select>
        <select
          value={filterStatus}
          onChange={(e) => setFilterStatus(e.target.value)}
          className={selectClassName + ' max-w-[10rem]'}
        >
          <option value="">{t('attendance_stations.filter_all_status', 'Tots els estats')}</option>
          <option value="active">active</option>
          <option value="pending">pending</option>
          <option value="suspended">suspended</option>
          <option value="retired">retired</option>
        </select>
        <select
          value={filterConnectivity}
          onChange={(e) => setFilterConnectivity(e.target.value)}
          className={selectClassName + ' max-w-[10rem]'}
        >
          <option value="">{t('attendance_stations.filter_all_conn', 'Totes les connexions')}</option>
          <option value="online">online</option>
          <option value="stale">stale</option>
          <option value="offline">offline</option>
          <option value="never_seen">never_seen</option>
          <option value="inactive">inactive</option>
        </select>
        {(filterSiteId || filterStatus || filterConnectivity) && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            onClick={() => {
              setFilterSiteId('')
              setFilterStatus('')
              setFilterConnectivity('')
            }}
          >
            {t('common.clear_filters', 'Netejar filtres')}
          </Button>
        )}
      </div>

      {canManage && selectedIds.length > 0 ? (
        <div className="flex flex-wrap items-center gap-2 rounded-xl border bg-muted/20 px-3 py-2">
          <span className="text-sm font-medium tabular-nums">
            {t('attendance_stations.bulk_selected', '{{count}} seleccionades', { count: selectedIds.length })}
          </span>
          <Button type="button" size="sm" variant="secondary" disabled={bulkOps.isPending} onClick={() => void runBulkStatus('suspended')}>
            {t('attendance_stations.bulk_suspend', 'Suspendre')}
          </Button>
          <Button type="button" size="sm" variant="secondary" disabled={bulkOps.isPending} onClick={() => void runBulkStatus('active')}>
            {t('attendance_stations.bulk_activate', 'Activar')}
          </Button>
          <Button type="button" size="sm" variant="outline" disabled={bulkOps.isPending} onClick={() => void runBulkLockdown(true)}>
            {t('attendance_stations.bulk_lockdown', 'Lockdown')}
          </Button>
          <Button type="button" size="sm" variant="outline" disabled={bulkOps.isPending} onClick={() => void runBulkLockdown(false)}>
            {t('attendance_stations.bulk_unlock', 'Desbloquejar')}
          </Button>
          <Button type="button" size="sm" variant="destructive" disabled={bulkRevoke.isPending} onClick={() => void runBulkRevoke()}>
            {t('attendance_stations.bulk_revoke', 'Revocar secrets')}
          </Button>
        </div>
      ) : null}

      {error ? (
        <div className="rounded-xl border border-destructive/30 bg-destructive/5 p-4 text-sm text-destructive">
          {(error as Error).message}
        </div>
      ) : null}

      <div className="overflow-hidden rounded-xl border">
        <Table>
          <TableHeader>
            <TableRow>
              {canManage ? (
                <TableHead className="w-10">
                  <input
                    type="checkbox"
                    checked={
                      filteredStations.length > 0 &&
                      filteredStations.every((s) => s.id && selectedIds.includes(s.id))
                    }
                    onChange={toggleSelectAllFiltered}
                    aria-label={t('attendance_stations.select_all', 'Seleccionar totes')}
                  />
                </TableHead>
              ) : null}
              <TableHead>{t('attendance_stations.col_name', 'Nom')}</TableHead>
              <TableHead>{t('attendance_stations.col_site', 'Centre')}</TableHead>
              <TableHead>{t('attendance_stations.col_location', 'Ubicació')}</TableHead>
              <TableHead>{t('attendance_stations.col_status', 'Estat')}</TableHead>
              <TableHead>{t('attendance_stations.col_connectivity', 'Connexió')}</TableHead>
              <TableHead>{t('attendance_stations.col_outbox', 'Cua')}</TableHead>
              <TableHead>{t('attendance_stations.col_last_seen', 'Darrera connexió')}</TableHead>
              <TableHead className="w-[240px]">{t('attendance_stations.col_actions', 'Accions')}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {isLoading ? (
              <TableRow>
                <TableCell colSpan={canManage ? 9 : 8} className="text-muted-foreground">
                  {t('common.loading', 'Carregant…')}
                </TableCell>
              </TableRow>
            ) : filteredStations.length === 0 ? (
              <TableRow>
                <TableCell colSpan={canManage ? 9 : 8} className="text-muted-foreground">
                  {t('attendance_stations.empty', 'Encara no hi ha estacions. Genera un codi d\'aparellament per començar.')}
                </TableCell>
              </TableRow>
            ) : (
              filteredStations.map((station) => (
                <TableRow key={station.id}>
                  {canManage ? (
                    <TableCell>
                      <input
                        type="checkbox"
                        checked={!!station.id && selectedIds.includes(station.id)}
                        onChange={() => station.id && toggleSelected(station.id)}
                        aria-label={t('attendance_stations.select_row', 'Seleccionar')}
                      />
                    </TableCell>
                  ) : null}
                  <TableCell className="font-medium">
                    <div className="flex flex-wrap items-center gap-1.5">
                      <span>{station.name ?? '—'}</span>
                      {station.ops_lockdown ? (
                        <Badge variant="destructive" className="text-[10px]">Lockdown</Badge>
                      ) : null}
                    </div>
                  </TableCell>
                  <TableCell>{siteNameById.get(station.site_id ?? '') ?? '—'}</TableCell>
                  <TableCell>
                    {station.location_id ? (
                      <Link
                        to={`/locations?locationId=${encodeURIComponent(station.location_id)}`}
                        className="text-primary hover:underline"
                      >
                        {station.location_path ?? station.location_id}
                      </Link>
                    ) : (
                      (station.location_path ?? '—')
                    )}
                  </TableCell>
                  <TableCell>{statusBadge(station.status)}</TableCell>
                  <TableCell>{connectivityBadge(station.connectivity_status)}</TableCell>
                  <TableCell className="text-xs tabular-nums text-muted-foreground">
                    {(station.outbox_pending_count ?? 0) > 0 || (station.outbox_quarantined_count ?? 0) > 0
                      ? `${station.outbox_pending_count ?? 0}p / ${station.outbox_quarantined_count ?? 0}q`
                      : '—'}
                  </TableCell>
                  <TableCell className="text-xs text-muted-foreground tabular-nums">
                    {station.last_seen_at
                      ? new Date(station.last_seen_at).toLocaleString()
                      : '—'}
                  </TableCell>
                  <TableCell>
                    <div className="flex flex-wrap gap-2">
                      <Button size="sm" variant="secondary" onClick={() => openHistory(station)}>
                        {t('attendance_stations.view_history', 'Historial')}
                      </Button>
                      <Button size="sm" variant="secondary" onClick={() => openAudit(station)}>
                        {t('attendance_stations.view_audit', 'Auditoria')}
                      </Button>
                      {canManage ? (
                        <>
                        <Button size="sm" variant="outline" onClick={() => openEdit(station)}>
                          {t('common.edit', 'Editar')}
                        </Button>
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() => {
                            if (station.id) revokeSecret.mutate(station.id)
                          }}
                          disabled={revokeSecret.isPending || !station.id}
                        >
                          {t('attendance_stations.revoke_secret', 'Revocar secret')}
                        </Button>
                        </>
                      ) : null}
                    </div>
                  </TableCell>
                </TableRow>
              ))
            )}
          </TableBody>
        </Table>
      </div>

      <Dialog open={pairOpen} onOpenChange={setPairOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('attendance_stations.pairing_title', 'Codi d\'aparellament')}</DialogTitle>
          </DialogHeader>
          {!pairResult ? (
            <div className="space-y-4">
              <p className="text-sm text-muted-foreground">
                {t(
                  'attendance_stations.pairing_help',
                  'Introdueix aquest codi a la tablet (/station). Opcionalment pre-assigna centre i ubicació.',
                )}
              </p>
              <div className="space-y-2">
                <Label>{t('attendance_stations.field_site', 'Centre')}</Label>
                <select
                  value={pairSiteId}
                  onChange={(e) => {
                    setPairSiteId(e.target.value)
                    setPairLocationId('')
                  }}
                  className={selectClassName}
                >
                  <option value="">{t('attendance_stations.site_unassigned', '— Sense assignar —')}</option>
                  {sites.map((site) => (
                    <option key={site.id} value={site.id}>{site.name}</option>
                  ))}
                </select>
              </div>
              <div className="space-y-2">
                <Label
                  className={!pairSiteId ? 'text-muted-foreground' : undefined}
                  htmlFor="pair-location-select"
                >
                  {t('attendance_stations.field_location', 'Ubicació')}
                </Label>
                <select
                  id="pair-location-select"
                  value={pairLocationId}
                  onChange={(e) => setPairLocationId(e.target.value)}
                  disabled={!pairSiteId}
                  aria-disabled={!pairSiteId}
                  className={`${selectClassName} disabled:cursor-not-allowed disabled:opacity-50`}
                >
                  <option value="">{t('attendance_stations.location_unassigned', '— Sense assignar —')}</option>
                  {pairLocations.map((loc) => {
                    const path = getAncestors(pairLocations, loc.id!).map((a) => a.name).join(' › ')
                    return (
                      <option key={loc.id} value={loc.id!}>
                        {path || loc.name}
                      </option>
                    )
                  })}
                </select>
                {!pairSiteId ? (
                  <p className="text-xs text-muted-foreground">
                    {t(
                      'attendance_stations.location_requires_site',
                      'Selecciona un centre per poder triar una ubicació.',
                    )}
                  </p>
                ) : null}
              </div>
            </div>
          ) : (
            <div className="space-y-3 text-center">
              <p className="text-sm text-muted-foreground">
                {t('attendance_stations.pairing_code_label', 'Codi (vàlid fins')}
                {' '}
                {new Date(pairResult.expires_at).toLocaleTimeString()}):
              </p>
              {pairQrDataUrl ? (
                <img
                  src={pairQrDataUrl}
                  alt={t('attendance_stations.pairing_qr_alt', 'QR d\'aparellament')}
                  className="mx-auto h-48 w-48 rounded-lg border bg-white p-2"
                />
              ) : null}
              <p className="text-3xl font-mono font-bold tracking-[0.3em]">{pairResult.code}</p>
              <p className="text-xs text-muted-foreground">
                {t(
                  'attendance_stations.pairing_qr_hint',
                  'Escaneja el QR des de la tablet (/station) o introdueix el codi manualment.',
                )}
              </p>
            </div>
          )}
          <DialogFooter>
            {!pairResult ? (
              <Button onClick={handleCreatePairing} disabled={createPairing.isPending}>
                {t('attendance_stations.generate_code', 'Generar codi')}
              </Button>
            ) : (
              <Button onClick={() => setPairOpen(false)}>{t('common.close', 'Tancar')}</Button>
            )}
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={editOpen} onOpenChange={setEditOpen}>
        <DialogContent className="flex max-h-[90vh] w-full max-w-lg flex-col gap-0 overflow-hidden p-0 sm:max-w-xl">
          <DialogHeader className="shrink-0 border-b px-6 py-4 pr-12">
            <DialogTitle>{t('attendance_stations.edit_title', 'Editar estació')}</DialogTitle>
          </DialogHeader>
          <div className="min-h-0 flex-1 space-y-4 overflow-y-auto px-6 py-4">
            <div className="space-y-2">
              <Label>{t('attendance_stations.field_name', 'Nom')}</Label>
              <Input value={editName} onChange={(e) => setEditName(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label>{t('attendance_stations.field_site', 'Centre')}</Label>
              <select
                value={editSiteId}
                onChange={(e) => {
                  setEditSiteId(e.target.value)
                  setEditLocationId('')
                }}
                className={selectClassName}
              >
                <option value="">—</option>
                {sites.map((site) => (
                  <option key={site.id} value={site.id}>{site.name}</option>
                ))}
              </select>
            </div>
            <div className="space-y-2">
              <Label>{t('attendance_stations.field_location', 'Ubicació')}</Label>
              <select
                value={editLocationId}
                onChange={(e) => {
                  const nextLocationId = e.target.value
                  setEditLocationId(nextLocationId)
                  const nextLocation = editLocations.find((loc) => loc.id === nextLocationId)
                  if (!extractLatLng(nextLocation?.geo_coordinates ?? null)) {
                    setEditGeoAntifraudEnabled(false)
                  }
                }}
                disabled={!editSiteId}
                className={selectClassName}
              >
                <option value="">—</option>
                {editLocations.map((loc) => {
                  const path = getAncestors(editLocations, loc.id!).map((a) => a.name).join(' › ')
                  return (
                    <option key={loc.id} value={loc.id!}>
                      {path || loc.name}
                    </option>
                  )
                })}
              </select>
            </div>
            <div className="space-y-2">
              <Label>{t('attendance_stations.field_status', 'Estat')}</Label>
              <select
                value={editStatus}
                onChange={(e) => setEditStatus(e.target.value)}
                className={selectClassName}
              >
                <option value="pending">Pendent</option>
                <option value="active">Activa</option>
                <option value="suspended">Suspesa</option>
                <option value="retired">Baixa</option>
              </select>
            </div>
            <div className="space-y-2">
              <Label>{t('attendance_stations.field_methods', 'Mètodes de fitxatge')}</Label>
              <div className="flex flex-col gap-2 text-sm">
                <label className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    checked={editAllowedManual}
                    onChange={(e) => setEditAllowedManual(e.target.checked)}
                  />
                  {t('attendance_stations.method_manual', 'Selecció manual a la tablet')}
                </label>
                <label className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    checked={editAllowedQr}
                    onChange={(e) => setEditAllowedQr(e.target.checked)}
                  />
                  {t('attendance_stations.method_qr', 'QR des del mòbil de l\'empleat')}
                </label>
              </div>
            </div>
            {editStation?.id && tenantId ? (
              <StationBrandingFields
                tenantId={tenantId}
                deviceId={editStation.id}
                displayTitle={editDisplayTitle}
                displayLogoUrl={editDisplayLogoUrl}
                onDisplayTitleChange={setEditDisplayTitle}
                onDisplayLogoUrlChange={setEditDisplayLogoUrl}
                disabled={updateStation.isPending}
              />
            ) : null}
            <div className="space-y-2 border-t pt-3">
              <Label>{t('attendance_stations.field_ux_preset', 'Preset de seguretat / UX')}</Label>
              <select
                value={editUxPreset}
                onChange={(e) => setEditUxPreset(e.target.value as StationUxPreset)}
                className={selectClassName}
              >
                {STATION_UX_PRESET_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>
                    {opt.label}
                  </option>
                ))}
              </select>
              <p className="text-xs text-muted-foreground">
                {STATION_UX_PRESET_OPTIONS.find((o) => o.value === editUxPreset)?.hint}
              </p>
            </div>
            <div className="space-y-2 border-t pt-3">
              <Label>{t('attendance_stations.field_entry_mode', 'Mode d\'entrada (kiosk)')}</Label>
              <select
                value={editEntryMode}
                onChange={(e) => {
                  setEditUxPreset('custom')
                  setEditEntryMode(e.target.value)
                }}
                disabled={editUxPreset !== 'custom'}
                className={selectClassName}
              >
                <option value="employee_list">Llista d&apos;empleats</option>
                <option value="document_entry">Document (DNI) — preferit</option>
              </select>
              <p className="text-xs text-muted-foreground">
                {t(
                  'attendance_stations.entry_mode_hint',
                  'Les estacions noves usen document per defecte. La llista i el QR queden com a canal secundari si estan habilitats.',
                )}
              </p>
            </div>
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-2">
                <Label>{t('attendance_stations.field_document_match', 'Coincidència document')}</Label>
                <select
                  value={editDocumentMatch}
                  onChange={(e) => setEditDocumentMatch(e.target.value)}
                  className={selectClassName}
                >
                  <option value="suffix">Sufix (mínim N caràcters)</option>
                  <option value="exact">Document complet</option>
                </select>
              </div>
              <div className="space-y-1">
                <Label htmlFor="document-suffix-length">
                  {t('attendance_stations.field_document_suffix', 'Longitud mínima sufix')}
                </Label>
                <Input
                  id="document-suffix-length"
                  type="number"
                  min={3}
                  max={8}
                  disabled={editDocumentMatch !== 'suffix'}
                  value={editDocumentSuffixLength}
                  onChange={(e) => setEditDocumentSuffixLength(Number(e.target.value) || 4)}
                />
              </div>
            </div>
            <div className="space-y-2">
              <Label>{t('attendance_stations.field_list_layout', 'Disposició de la llista')}</Label>
              <select
                value={editListLayout}
                onChange={(e) => setEditListLayout(e.target.value)}
                className={selectClassName}
              >
                <option value="compact">Compacta (2 columnes)</option>
                <option value="two_column">Dues columnes</option>
                <option value="search_first">Cerca destacada</option>
              </select>
            </div>
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-2">
                <Label>{t('attendance_stations.field_identity_confirm', 'Confirmació (llista)')}</Label>
                <select
                  value={editIdentityConfirm}
                  onChange={(e) => setEditIdentityConfirm(e.target.value)}
                  className={selectClassName}
                >
                  <option value="none">Cap (directe a sessió)</option>
                  <option value="tap_name">Confirmar «Ets X?»</option>
                  <option value="portal_pin">PIN del portal empleat</option>
                </select>
              </div>
              <div className="space-y-2">
                <Label>{t('attendance_stations.field_qr_identity_confirm', 'Confirmació (QR)')}</Label>
                <select
                  value={editQrIdentityConfirm}
                  onChange={(e) => setEditQrIdentityConfirm(e.target.value)}
                  className={selectClassName}
                >
                  <option value="none">Cap (directe a sessió)</option>
                  <option value="tap_name">Confirmar «Ets X?»</option>
                  <option value="portal_pin">PIN del portal empleat</option>
                </select>
              </div>
            </div>
            <p className="text-xs text-muted-foreground">
              {t(
                'attendance_stations.portal_pin_hint',
                'El PIN d\'empleat és el del portal. Si l\'empleat no en té, el kiosk demana «Ets X?». El PIN local de l\'estació continua només per admin.',
              )}
            </p>
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-1">
                <Label htmlFor="session-idle">
                  {t('attendance_stations.field_session_idle', 'Inactivitat sessió (s)')}
                </Label>
                <Input
                  id="session-idle"
                  type="number"
                  min={15}
                  max={600}
                  value={editSessionIdleSeconds}
                  onChange={(e) => setEditSessionIdleSeconds(Number(e.target.value) || 60)}
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="session-countdown">
                  {t('attendance_stations.field_session_countdown', 'Countdown post-fitxatge (s)')}
                </Label>
                <Input
                  id="session-countdown"
                  type="number"
                  min={5}
                  max={120}
                  value={editSessionCountdownSeconds}
                  onChange={(e) => setEditSessionCountdownSeconds(Number(e.target.value) || 15)}
                />
              </div>
            </div>
            <label className="flex items-start gap-2 text-sm">
              <input
                type="checkbox"
                className="mt-1"
                checked={editSessionAllowHistory}
                onChange={(e) => setEditSessionAllowHistory(e.target.checked)}
              />
              <span>
                {t(
                  'attendance_stations.field_session_history',
                  'Permetre historial a la sessió d\'empleat (requereix PIN del portal)',
                )}
              </span>
            </label>
            {editSessionAllowHistory ? (
              <div className="space-y-1">
                <Label htmlFor="session-history-max-days">
                  {t('attendance_stations.field_session_history_max_days', 'Rang màxim historial (dies)')}
                </Label>
                <Input
                  id="session-history-max-days"
                  type="number"
                  min={1}
                  max={90}
                  value={editSessionHistoryMaxDays}
                  onChange={(e) => {
                    setEditUxPreset('custom')
                    setEditSessionHistoryMaxDays(Number(e.target.value) || 90)
                  }}
                  disabled={editUxPreset !== 'custom'}
                />
                <p className="text-xs text-muted-foreground">
                  {t(
                    'attendance_stations.field_session_history_max_hint',
                    'Per defecte 90. El servidor rebutja períodes més amplis.',
                  )}
                </p>
              </div>
            ) : null}
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-1">
                <Label htmlFor="waiting-idle">
                  {t('attendance_stations.field_waiting_idle', 'Auto-blank espera (s)')}
                </Label>
                <Input
                  id="waiting-idle"
                  type="number"
                  min={0}
                  max={600}
                  value={editWaitingIdleSeconds}
                  onChange={(e) => {
                    setEditUxPreset('custom')
                    setEditWaitingIdleSeconds(Number(e.target.value) || 0)
                  }}
                  disabled={editUxPreset !== 'custom'}
                />
                <p className="text-xs text-muted-foreground">
                  {t(
                    'attendance_stations.field_waiting_idle_hint',
                    '0 = desactivat. Mínim 30 s si s\'activa. Amaga la llista després d\'inactivitat.',
                  )}
                </p>
              </div>
              <label className="flex items-start gap-2 self-end pb-2 text-sm">
                <input
                  type="checkbox"
                  className="mt-1"
                  checked={editMaskNamesOnWaiting}
                  disabled={editUxPreset !== 'custom'}
                  onChange={(e) => {
                    setEditUxPreset('custom')
                    setEditMaskNamesOnWaiting(e.target.checked)
                  }}
                />
                <span>
                  {t(
                    'attendance_stations.field_mask_names',
                    'Emmascarar noms a la pantalla d\'espera',
                  )}
                </span>
              </label>
            </div>
            <div className="space-y-2">
              <Label>{t('attendance_stations.field_geo_antifraud', 'Validació geo anti-frau')}</Label>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={editGeoAntifraudEnabled}
                  disabled={!editLocationHasGeo}
                  onChange={(e) => setEditGeoAntifraudEnabled(e.target.checked)}
                />
                {t(
                  'attendance_stations.geo_antifraud_enabled',
                  'Comprovar que la tablet està a la ubicació (no es guarda GPS al fitxatge)',
                )}
              </label>
              {!editLocationHasGeo ? (
                <p className="text-xs text-muted-foreground">
                  {t(
                    'attendance_stations.geo_antifraud_requires_location',
                    'La ubicació seleccionada no té coordenades GPS. Defineix-les a /locations.',
                  )}
                </p>
              ) : null}
              {editGeoAntifraudEnabled && editLocationHasGeo ? (
                <div className="space-y-1">
                  <Label htmlFor="geo-antifraud-radius">
                    {t('attendance_stations.geo_antifraud_radius', 'Radi màxim (metres)')}
                  </Label>
                  <Input
                    id="geo-antifraud-radius"
                    type="number"
                    min={25}
                    max={2000}
                    value={editGeoAntifraudRadiusM}
                    onChange={(e) => setEditGeoAntifraudRadiusM(Number(e.target.value) || 150)}
                  />
                  <p className="text-xs text-muted-foreground">
                    {t('attendance_stations.geo_antifraud_radius_hint', 'Per defecte 150 m, rang 25–2000 m.')}
                  </p>
                </div>
              ) : null}
            </div>
            <div className="space-y-2">
              <Label>
                {t(
                  'attendance_stations.field_scheduled_location',
                  'Ubicació planificada vs estació',
                )}
              </Label>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={editWarnWrongScheduledLocation}
                  onChange={(e) => setEditWarnWrongScheduledLocation(e.target.checked)}
                />
                {t(
                  'attendance_stations.warn_wrong_scheduled_location',
                  'Avisar si la ubicació del torn no coincideix (recomanat)',
                )}
              </label>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={editBlockWrongScheduledLocation}
                  onChange={(e) => setEditBlockWrongScheduledLocation(e.target.checked)}
                />
                {t(
                  'attendance_stations.block_wrong_scheduled_location',
                  'Bloquejar el fitxatge si no coincideix (opcional)',
                )}
              </label>
              <p className="text-xs text-muted-foreground">
                {t(
                  'attendance_stations.scheduled_location_hint',
                  'Per defecte només s\'avisa i es registra l\'anomalia WRONG_SCHEDULED_LOCATION.',
                )}
              </p>
            </div>
            <div className="space-y-2">
              <Label>
                {t(
                  'attendance_stations.field_unassigned_punch',
                  'Fitxatge sense assignació de zona',
                )}
              </Label>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={editAllowUnassignedPunch}
                  onChange={(e) => setEditAllowUnassignedPunch(e.target.checked)}
                />
                {t(
                  'attendance_stations.allow_unassigned_punch',
                  'Permetre fitxar si l\'empleat no està assignat a aquesta zona',
                )}
              </label>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={editWarnUnassignedPunch}
                  disabled={!editAllowUnassignedPunch}
                  onChange={(e) => setEditWarnUnassignedPunch(e.target.checked)}
                />
                {t(
                  'attendance_stations.warn_unassigned_punch',
                  'Mostrar avís a la sessió (recomanat)',
                )}
              </label>
              <p className="text-xs text-muted-foreground">
                {t(
                  'attendance_stations.unassigned_punch_hint',
                  'Si es permet, el fitxatge registra l\'anomalia OUTSIDE_ASSIGNMENT. Si es desactiva, es bloqueja com abans.',
                )}
              </p>
            </div>
            <p className="text-xs text-muted-foreground">
              {t(
                'attendance_stations.active_requires_location',
                'Per activar cal centre, ubicació i que l\'estació s\'hagi aparellat (secret + PIN).',
              )}
            </p>
          </div>
          <DialogFooter className="shrink-0 border-t px-6 py-4 sm:justify-end">
            <Button
              type="button"
              variant="outline"
              onClick={() => setEditOpen(false)}
              disabled={updateStation.isPending}
            >
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button onClick={handleSaveEdit} disabled={updateStation.isPending}>
              {t('common.save', 'Desar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <StationHistoryDrawer
        station={historyStation}
        siteName={historyStation?.site_id ? siteNameById.get(historyStation.site_id) ?? null : null}
        open={historyOpen}
        onOpenChange={(next) => {
          setHistoryOpen(next)
          if (!next) setHistoryStation(null)
        }}
      />

      <StationAdminAuditDrawer
        station={auditStation}
        open={auditOpen}
        onOpenChange={(next) => {
          setAuditOpen(next)
          if (!next) setAuditStation(null)
        }}
      />
    </div>
  )
}
