import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2, MapPin, Smartphone } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Badge } from '@/components/ui/badge'
import type { TimePunch } from '../../api/attendanceService'
import { formatDayDetailTime, formatWorkDateLabel } from '../../api/dayDetailService'
import { useAttendanceDayDetail } from '../../api/useAttendanceDayDetail'
import {
  formatDeviceInfoRows,
  formatLocationPermissionLabel,
  formatPunchSourceLabel,
} from '../../utils/deviceInfo'
import { DailyTimeline } from '../DailyTimeline'
import { AnomalyAlert } from '../AnomalyAlert'

import { APIProvider, Map as GoogleMap, Marker } from '@vis.gl/react-google-maps'
import { useMapsJsBrowserConfig } from '@/hooks/useMapsJsApiKey'

const DEFAULT_CENTER = { lat: 41.3874, lng: 2.1686 }

const PUNCH_COLORS = ['#059669', '#2563eb', '#d97706', '#7c3aed', '#dc2626', '#0891b2']

export interface PunchDetailsSelection {
  employeeId: string
  employeeName: string
  workDate: string
}

interface PunchDetailsDialogProps {
  selection: PunchDetailsSelection | null
  open: boolean
  onOpenChange: (open: boolean) => void
}

function punchTypeLabel(
  punchType: string | null | undefined,
  t: (key: string, fallback: string) => string,
): string {
  switch (punchType) {
    case 'in':
      return t('timeline.type_in', 'Entrada')
    case 'out':
      return t('timeline.type_out', 'Sortida')
    case 'break_start':
      return t('timeline.type_break_start', 'Inici pausa')
    case 'break_end':
      return t('timeline.type_break_end', 'Fi pausa')
    default:
      return punchType ?? '—'
  }
}

function PunchGeoMap({ punches }: { punches: TimePunch[] }) {
  const { data: mapsJsConfig } = useMapsJsBrowserConfig(true)
  const mapsJsApiKey = mapsJsConfig?.apiKey
  const mapsJsMapId = mapsJsConfig?.mapId ?? undefined
  const geoPunches = punches.filter((p) => p.geo_lat != null && p.geo_lng != null)

  const center = useMemo(() => {
    if (geoPunches.length === 0) return DEFAULT_CENTER
    const lat = geoPunches.reduce((s, p) => s + Number(p.geo_lat), 0) / geoPunches.length
    const lng = geoPunches.reduce((s, p) => s + Number(p.geo_lng), 0) / geoPunches.length
    return { lat, lng }
  }, [geoPunches])

  if (geoPunches.length === 0) {
    return (
      <div className="flex h-48 items-center justify-center rounded-lg border bg-muted/20 text-sm text-muted-foreground">
        Sense coordenades GPS en aquest dia
      </div>
    )
  }

  const googleAvailable = Boolean(mapsJsApiKey)
  if (!googleAvailable) {
    return (
      <div className="h-48 overflow-hidden rounded-lg border md:h-56 flex items-center justify-center text-sm text-muted-foreground bg-muted/20">
        Sense clau Maps JS activa
      </div>
    )
  }

  return (
    <div className="h-48 overflow-hidden rounded-lg border md:h-56">
      <APIProvider apiKey={mapsJsApiKey!} libraries={[]}>
        <GoogleMap
          mapId={mapsJsMapId}
          center={center}
          zoom={geoPunches.length === 1 ? 15 : 14}
          className="h-full w-full"
        >
          {geoPunches.map((punch, idx) => (
            <Marker
              key={punch.id ?? idx}
              position={{ lat: Number(punch.geo_lat), lng: Number(punch.geo_lng) }}
            />
          ))}
        </GoogleMap>
      </APIProvider>
    </div>
  )
}

function PunchDetailCard({
  punch,
  index,
  t,
}: {
  punch: TimePunch
  index: number
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
}) {
  const hasGeo = punch.geo_lat != null && punch.geo_lng != null
  const deviceRows = formatDeviceInfoRows(punch.device_info, t, { source: punch.source })
  const sourceLabel = formatPunchSourceLabel(punch.source, t)
  const color = PUNCH_COLORS[index % PUNCH_COLORS.length]

  return (
    <article className="rounded-lg border bg-card p-3 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="flex items-center gap-2">
          <span
            className="h-2.5 w-2.5 shrink-0 rounded-full"
            style={{ backgroundColor: color }}
            aria-hidden
          />
          <div>
            <p className="text-sm font-semibold">{punchTypeLabel(punch.punch_type, t)}</p>
            <p className="text-xs tabular-nums text-muted-foreground">
              {formatDayDetailTime(punch.occurred_at)}
            </p>
          </div>
        </div>
        <div className="flex flex-wrap gap-1">
          {punch.is_remote && (
            <Badge variant="outline" className="text-[10px]">
              {t('dashboard.remote', 'remot')}
            </Badge>
          )}
          {sourceLabel && (
            <Badge variant="secondary" className="text-[10px]">
              {sourceLabel}
            </Badge>
          )}
        </div>
      </div>

      {hasGeo ? (
        <div className="mt-3 space-y-1 rounded-md bg-muted/30 p-2 text-xs">
          <p className="flex items-center gap-1.5 font-medium text-foreground">
            <MapPin className="h-3.5 w-3.5 text-primary" aria-hidden />
            {t('punch_details.geo_title', 'Geolocalització')}
          </p>
          <p className="font-mono tabular-nums text-muted-foreground">
            {Number(punch.geo_lat).toFixed(5)}, {Number(punch.geo_lng).toFixed(5)}
          </p>
          {punch.geo_accuracy_m != null && (
            <p>
              {t('punch_details.accuracy', 'Precisió')}: ±{Math.round(punch.geo_accuracy_m)} m
            </p>
          )}
          {punch.geo_altitude_m != null && (
            <p>
              {t('punch_details.altitude', 'Altitud')}: {Math.round(punch.geo_altitude_m)} m
            </p>
          )}
          {punch.geo_speed_ms != null && (
            <p>
              {t('punch_details.speed', 'Velocitat')}: {Number(punch.geo_speed_ms).toFixed(1)} m/s
            </p>
          )}
          {punch.location_permission && (
            <p>
              {t('punch_details.location_permission', 'Permís ubicació')}:{' '}
              {formatLocationPermissionLabel(punch.location_permission, t)}
            </p>
          )}
          {'geo_error' in punch && punch.geo_error ? (
            <p className="text-amber-800">{String(punch.geo_error)}</p>
          ) : null}
        </div>
      ) : (
        <p className="mt-2 text-xs text-muted-foreground">
          {t('punch_details.no_geo', 'Sense coordenades GPS en aquest fitxatge')}
        </p>
      )}

      {((punch.location_name_snapshot || punch.device_name_snapshot)) && (
        <div className="mt-2 space-y-1 rounded-md bg-muted/20 p-2 text-xs">
          <p className="font-medium">{t('punch_details.work_location', 'Ubicació de treball')}</p>
          {punch.location_name_snapshot ? (
            <p className="text-muted-foreground">{punch.location_name_snapshot}</p>
          ) : null}
          {punch.device_name_snapshot ? (
            <p className="text-muted-foreground">
              {t('punch_details.station', 'Estació')}: {punch.device_name_snapshot}
            </p>
          ) : null}
        </div>
      )}

      {deviceRows.length > 0 ? (
        <div className="mt-2 space-y-1 rounded-md bg-muted/20 p-2 text-xs">
          <p className="flex items-center gap-1.5 font-medium">
            <Smartphone className="h-3.5 w-3.5" aria-hidden />
            {t('punch_details.device', 'Dispositiu')}
          </p>
          {deviceRows.map(({ label, value }) => (
            <p key={label} className="break-all text-muted-foreground">
              <span className="font-medium text-foreground">{label}</span>: {value}
            </p>
          ))}
          {punch.device_id && (
            <p className="font-mono text-[10px] text-muted-foreground">id: {punch.device_id}</p>
          )}
        </div>
      ) : (
        <p className="mt-2 text-xs text-muted-foreground">
          {t('punch_details.no_device', 'Sense dades del dispositiu enregistrades')}
        </p>
      )}

      {(punch.anomaly_codes?.length ?? 0) > 0 && (
        <div className="mt-2">
          <AnomalyAlert codes={punch.anomaly_codes!} />
        </div>
      )}

      {punch.notes && (
        <p className="mt-2 text-xs italic text-muted-foreground">{punch.notes}</p>
      )}
    </article>
  )
}

export function PunchDetailsDialog({ selection, open, onOpenChange }: PunchDetailsDialogProps) {
  const { t } = useTranslation('attendance')
  const { data, isLoading, error } = useAttendanceDayDetail(
    selection?.employeeId ?? null,
    selection?.workDate ?? null,
    open,
  )

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] max-w-3xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {selection
              ? t('punch_details.title', 'Fitxatges — {{name}}', { name: selection.employeeName })
              : t('punch_details.title_generic', 'Fitxatges del dia')}
          </DialogTitle>
          {selection && (
            <DialogDescription className="capitalize">
              {formatWorkDateLabel(selection.workDate)}
            </DialogDescription>
          )}
        </DialogHeader>

        {isLoading && (
          <div className="flex justify-center py-16">
            <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
          </div>
        )}

        {error && (
          <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-4 text-sm text-destructive">
            {error.message}
          </div>
        )}

        {data && !isLoading && (
          <div className="space-y-4">
            {data.punches.length === 0 ? (
              <p className="py-8 text-center text-sm text-muted-foreground">
                {t('day_detail.no_punches', 'Cap fitxatge enregistrat aquest dia.')}
              </p>
            ) : (
              <>
                <PunchGeoMap punches={data.punches} />
                <DailyTimeline
                  punches={data.punches}
                  title={t('day_detail.punch_list', 'Seqüència')}
                />
                <div className="space-y-3">
                  <h3 className="text-sm font-semibold">
                    {t('punch_details.detail_heading', 'Detall per fitxatge')}
                  </h3>
                  {data.punches.map((punch, idx) => (
                    <PunchDetailCard key={punch.id ?? idx} punch={punch} index={idx} t={t} />
                  ))}
                </div>
              </>
            )}
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
