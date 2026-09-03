import { Link } from 'react-router-dom'
import type { TFunction } from 'i18next'
import { MonitorSmartphone } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { useTenant } from '@/contexts/TenantContext'
import { useStationFleetHealth } from '@/features/attendance-stations/api/useAttendanceStations'

export function DashboardStationFleetWidget({ t }: { t: TFunction }) {
  const { activeTenant } = useTenant()
  const { data: health, isLoading } = useStationFleetHealth(activeTenant?.id)

  const offline =
    (health?.station_counts.offline ?? 0) +
    (health?.station_counts.stale ?? 0) +
    (health?.station_counts.never_seen ?? 0)
  const pending = health?.outbox.pending_total ?? 0
  const lockdown = health?.outbox.lockdown_count ?? 0
  const online = health?.station_counts.online ?? 0

  return (
    <div className="rounded-xl border p-4 space-y-3">
      <div className="flex items-start justify-between gap-2">
        <div>
          <p className="flex items-center gap-1.5 text-sm font-semibold">
            <MonitorSmartphone className="h-4 w-4" aria-hidden />
            {t('dashboard.station_fleet_title', 'Estacions')}
          </p>
          <p className="text-xs text-muted-foreground">
            {t('dashboard.station_fleet_hint', 'Estat de les estacions de fitxatge')}
          </p>
        </div>
        {isLoading ? (
          <Badge variant="outline" className="text-[10px]">…</Badge>
        ) : offline > 0 || lockdown > 0 || pending > 0 ? (
          <Badge variant="destructive" className="text-[10px]">
            {t('dashboard.station_fleet_attention', 'Atenció')}
          </Badge>
        ) : (
          <Badge variant="secondary" className="text-[10px]">
            {t('dashboard.station_fleet_ok', 'OK')}
          </Badge>
        )}
      </div>

      <div className="grid grid-cols-2 gap-2 text-sm">
        <div className="rounded-lg bg-muted/40 px-2.5 py-2">
          <p className="text-[11px] text-muted-foreground">{t('dashboard.station_fleet_online', 'En línia')}</p>
          <p className="font-semibold tabular-nums">{online}</p>
        </div>
        <div className="rounded-lg bg-muted/40 px-2.5 py-2">
          <p className="text-[11px] text-muted-foreground">{t('dashboard.station_fleet_offline', 'Problemes connexió')}</p>
          <p className="font-semibold tabular-nums">{offline}</p>
        </div>
        <div className="rounded-lg bg-muted/40 px-2.5 py-2">
          <p className="text-[11px] text-muted-foreground">{t('dashboard.station_fleet_queue', 'Cua offline')}</p>
          <p className="font-semibold tabular-nums">{pending}</p>
        </div>
        <div className="rounded-lg bg-muted/40 px-2.5 py-2">
          <p className="text-[11px] text-muted-foreground">{t('dashboard.station_fleet_lockdown', 'Lockdown')}</p>
          <p className="font-semibold tabular-nums">{lockdown}</p>
        </div>
      </div>

      <Link to="/settings/attendance-stations" className="text-xs text-primary underline">
        {t('dashboard.station_fleet_link', 'Veure estacions')}
      </Link>
    </div>
  )
}
