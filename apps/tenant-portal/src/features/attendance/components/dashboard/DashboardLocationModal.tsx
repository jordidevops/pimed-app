import type { TFunction } from 'i18next'
import { MapPin } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import type { TodayDashboardRow } from '../../api/todayDashboardService'
import { formatPunchTime, punchTypeKey } from '../../api/todayDashboardService'
import { formatIntervalsList } from '../../api/workIntervals'

import { APIProvider, Map as GoogleMap, Marker } from '@vis.gl/react-google-maps'
import { useMapsJsBrowserConfig } from '@/hooks/useMapsJsApiKey'

const DEFAULT_CENTER = { lat: 41.3874, lng: 2.1686 }

interface DashboardLocationModalProps {
  rows: TodayDashboardRow[]
  open: boolean
  onOpenChange: (open: boolean) => void
  focusRow?: TodayDashboardRow | null
  t: TFunction
  overnightSuffix: string
}

export function employeeDashboardHref(employeeId: string) {
  return `/employees/${employeeId}?tab=timesheet`
}

export function DashboardLocationModal({
  rows,
  open,
  onOpenChange,
  focusRow,
  t,
  overnightSuffix,
}: DashboardLocationModalProps) {
  const points = rows.filter((r) => r.geo_lat != null && r.geo_lng != null)

  const { data: mapsJsConfig } = useMapsJsBrowserConfig(true)
  const mapsJsApiKey = mapsJsConfig?.apiKey
  const mapsJsMapId = mapsJsConfig?.mapId ?? undefined
  const googleAvailable = Boolean(mapsJsApiKey)

  const center = (() => {
    if (focusRow?.geo_lat != null && focusRow?.geo_lng != null) {
      return { lat: Number(focusRow.geo_lat), lng: Number(focusRow.geo_lng) }
    }
    if (points.length === 0) return DEFAULT_CENTER
    const lat = points.reduce((s, p) => s + Number(p.geo_lat), 0) / points.length
    const lng = points.reduce((s, p) => s + Number(p.geo_lng), 0) / points.length
    return { lat, lng }
  })()

  const displayRows = focusRow ? [focusRow] : points

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-3xl gap-0 p-0">
        <DialogHeader className="border-b px-4 py-3">
          <DialogTitle className="flex items-center gap-2 text-base">
            <MapPin className="h-4 w-4" />
            {focusRow
              ? t('dashboard.map_employee_title', 'Ubicació — {{name}}', { name: focusRow.employee_name })
              : t('dashboard.map_title', 'Ubicacions')}
          </DialogTitle>
          <p className="text-xs text-muted-foreground">
            {t('dashboard.map_modal_subtitle', 'Darrer fitxatge amb geolocalització per empleat')}
          </p>
        </DialogHeader>
        <div className="grid gap-0 md:grid-cols-5">
          <div className="md:col-span-3">
            <div className="h-72 md:h-96">
              {points.length === 0 ? (
                <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
                  {t('dashboard.map_empty', 'Sense coordenades GPS avui')}
                </div>
              ) : (
                googleAvailable ? (
                  <APIProvider apiKey={mapsJsApiKey!} libraries={[]}>
                    <GoogleMap
                      mapId={mapsJsMapId}
                      className="h-full w-full"
                      center={center}
                      zoom={focusRow ? 15 : 13}
                    >
                      {points.map((row) => (
                        <Marker
                          key={row.employee_id}
                          position={{ lat: Number(row.geo_lat), lng: Number(row.geo_lng) }}
                        />
                      ))}
                    </GoogleMap>
                  </APIProvider>
                ) : (
                  <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
                    {t('dashboard.map_visual_unavailable', 'Mapa visual no disponible')}
                  </div>
                )
              )}
            </div>
          </div>
          <div className="max-h-72 overflow-y-auto border-t md:col-span-2 md:max-h-96 md:border-l md:border-t-0">
            {displayRows.length === 0 ? (
              <p className="p-4 text-sm text-muted-foreground">
                {t('dashboard.map_empty', 'Sense coordenades GPS avui')}
              </p>
            ) : (
              <ul className="divide-y">
                {displayRows.map((row) => (
                  <li key={row.employee_id} className="p-3">
                    <LocationDetail row={row} t={t} overnightSuffix={overnightSuffix} linkName />
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      </DialogContent>
    </Dialog>
  )
}

function LocationDetail({
  row,
  t,
  overnightSuffix,
  linkName = false,
}: {
  row: TodayDashboardRow
  t: TFunction
  overnightSuffix: string
  linkName?: boolean
}) {
  const typeKey = punchTypeKey(row.last_punch_type)
  const typeLabel = typeKey ? t(`dashboard.punch_${typeKey}`, typeKey) : row.last_punch_type ?? '—'

  return (
    <div className="space-y-1 text-sm">
      {linkName ? (
        <a
          href={employeeDashboardHref(row.employee_id)}
          className="font-semibold text-primary hover:underline"
        >
          {row.employee_name}
        </a>
      ) : (
        <p className="font-semibold">{row.employee_name}</p>
      )}
      <p className="text-xs text-muted-foreground">
        {t(`control_horari.state.${row.current_state}`, row.current_state)}
      </p>
      {row.last_punch_at && (
        <p className="text-xs">
          <span className="font-medium tabular-nums">{formatPunchTime(row.last_punch_at)}</span>
          <span className="text-muted-foreground"> · {typeLabel}</span>
          {row.last_is_remote && (
            <span className="ml-1 text-[10px] uppercase text-muted-foreground">
              ({t('dashboard.remote', 'remot')})
            </span>
          )}
        </p>
      )}
      {row.geo_lat != null && row.geo_lng != null && (
        <p className="text-[10px] tabular-nums text-muted-foreground">
          {Number(row.geo_lat).toFixed(5)}, {Number(row.geo_lng).toFixed(5)}
          {row.geo_accuracy_m != null && (
            <span> · ±{Math.round(row.geo_accuracy_m)}m</span>
          )}
        </p>
      )}
      {row.work_intervals.length > 0 && (
        <p className="text-[10px] tabular-nums text-muted-foreground">
          {formatIntervalsList(row.work_intervals, overnightSuffix)}
        </p>
      )}
    </div>
  )
}
