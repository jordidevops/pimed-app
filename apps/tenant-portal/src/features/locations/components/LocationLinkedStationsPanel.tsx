import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Loader2, MonitorSmartphone } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { useAttendanceStations } from '@/features/attendance-stations/api/useAttendanceStations'
import type { Location } from '../api/locationsService'

export interface LocationLinkedStationsPanelProps {
  location: Location
}

export function LocationLinkedStationsPanel({ location }: LocationLinkedStationsPanelProps) {
  const { t } = useTranslation('locations')
  const locationId = location.id ?? null
  const { data: stations = [], isLoading, error } = useAttendanceStations()

  const linked = stations.filter((station) => station.location_id === locationId)

  return (
    <div className="rounded-xl border p-3 space-y-2.5">
      <p className="text-xs font-semibold text-foreground uppercase tracking-wide flex items-center gap-1.5">
        <MonitorSmartphone className="h-3.5 w-3.5" aria-hidden />
        {t('locations.linked_stations.title', 'Estacions vinculades')}
      </p>
      <p className="text-[11px] text-muted-foreground leading-relaxed">
        {t(
          'locations.linked_stations.explanation',
          'Estacions de fitxatge assignades a aquesta ubicació (només lectura).',
        )}
      </p>

      {isLoading ? (
        <div className="flex justify-center py-4 text-muted-foreground">
          <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
        </div>
      ) : error ? (
        <p className="rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-xs text-destructive">
          {(error as Error).message}
        </p>
      ) : linked.length === 0 ? (
        <p className="text-xs text-muted-foreground py-1">
          {t('locations.linked_stations.empty', 'Cap estació vinculada a aquesta ubicació.')}
        </p>
      ) : (
        <ul className="space-y-1.5">
          {linked.map((station) => (
            <li
              key={station.id}
              className="flex items-center justify-between gap-2 rounded-lg border px-2.5 py-2 text-sm"
            >
              <div className="min-w-0">
                <Link
                  to="/settings/attendance-stations"
                  className="font-medium text-primary hover:underline truncate block"
                >
                  {station.name ?? station.id}
                </Link>
                <p className="text-[11px] text-muted-foreground truncate">
                  {station.location_path ?? '—'}
                </p>
              </div>
              <Badge variant="outline" className="shrink-0 text-[10px]">
                {station.status ?? '—'}
              </Badge>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
