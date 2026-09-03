import { useMemo, useState, useEffect, useRef } from 'react'
import type { TFunction } from 'i18next'
import { MapPin, Maximize2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import type { TodayDashboardRow } from '../../api/todayDashboardService'
import { DashboardLocationModal } from './DashboardLocationModal'

import { APIProvider, Map as GoogleMap, Marker } from '@vis.gl/react-google-maps'
import { useMapsJsBrowserConfig } from '@/hooks/useMapsJsApiKey'

interface DashboardMapProps {
  rows: TodayDashboardRow[]
  t: TFunction
  overnightSuffix: string
  compact?: boolean
  fillHeight?: boolean
}

export function DashboardMap({ rows, t, overnightSuffix, compact = false, fillHeight = false }: DashboardMapProps) {
  const [modalOpen, setModalOpen] = useState(false)

  const points = useMemo(
    () => rows.filter((r) => r.geo_lat != null && r.geo_lng != null),
    [rows],
  )

  const { data: mapsJsConfig } = useMapsJsBrowserConfig(true)
  const mapsJsApiKey = mapsJsConfig?.apiKey
  const mapsJsMapId = mapsJsConfig?.mapId ?? undefined
  const mapsJsAvailable = Boolean(mapsJsApiKey)

  const center = useMemo(() => {
    if (points.length === 0) return { lat: 41.3874, lng: 2.1686 }
    const lat = points.reduce((s, p) => s + Number(p.geo_lat), 0) / points.length
    const lng = points.reduce((s, p) => s + Number(p.geo_lng), 0) / points.length
    return { lat, lng }
  }, [points])

  return (
    <>
      <div className={cn(
        'flex flex-col overflow-hidden rounded-xl border bg-card shadow-sm',
        fillHeight ? 'h-full w-full' : '',
      )}
      >
        <div className="flex shrink-0 items-center justify-between border-b px-4 py-3">
          <div>
            <h2 className="font-semibold">{t('dashboard.map_title', 'Ubicacions')}</h2>
            <p className="text-xs text-muted-foreground">
              {t('dashboard.map_subtitle', '{{count}} posicions amb geo', { count: points.length })}
            </p>
          </div>
          <Button type="button" variant="outline" size="sm" onClick={() => setModalOpen(true)}>
            <Maximize2 className="h-4 w-4" />
            <span className="ml-1.5 hidden sm:inline">
              {t('dashboard.map_expand', 'Ampliar')}
            </span>
          </Button>
        </div>
        <div className={cn(
          'relative min-h-0',
          fillHeight ? 'min-h-[12rem] flex-1' : compact ? 'h-40' : 'h-56',
        )}
        >
          {points.length === 0 ? (
            <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
              {t('dashboard.map_empty', 'Sense coordenades GPS avui')}
            </div>
          ) : mapsJsAvailable ? (
            <APIProvider apiKey={mapsJsApiKey!} libraries={[]}>
              <GoogleMap
                mapId={mapsJsMapId}
                className="absolute inset-0 h-full w-full"
                center={center}
                zoom={12}
                onClick={() => {
                  // Intentionally no-op: marker click opens the modal.
                }}
              >
                {points.map((row) => (
                  <Marker
                    key={row.employee_id}
                    position={{ lat: Number(row.geo_lat), lng: Number(row.geo_lng) }}
                    onClick={() => setModalOpen(true)}
                  />
                ))}
              </GoogleMap>
            </APIProvider>
          ) : (
            <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
              {t('dashboard.map_empty', 'Sense coordenades GPS i mapa visual no disponible')}
            </div>
          )}
        </div>
      </div>

      <DashboardLocationModal
        rows={rows}
        open={modalOpen}
        onOpenChange={setModalOpen}
        t={t}
        overnightSuffix={overnightSuffix}
      />
    </>
  )
}

interface DashboardMapPreviewProps {
  row: TodayDashboardRow
  t: TFunction
  overnightSuffix: string
}

export function DashboardMapPreview({ row, t, overnightSuffix }: DashboardMapPreviewProps) {
  const [modalOpen, setModalOpen] = useState(false)
  const hasGeo = row.geo_lat != null && row.geo_lng != null

  if (!hasGeo) return <span className="text-muted-foreground">—</span>

  return (
    <>
      <button
        type="button"
        onClick={() => setModalOpen(true)}
        className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-xs text-primary hover:bg-accent"
        title={t('dashboard.map_view_location', 'Veure ubicació')}
      >
        <MapPin className="h-3.5 w-3.5" />
      </button>
      <DashboardLocationModal
        rows={[row]}
        open={modalOpen}
        onOpenChange={setModalOpen}
        focusRow={row}
        t={t}
        overnightSuffix={overnightSuffix}
      />
    </>
  )
}
