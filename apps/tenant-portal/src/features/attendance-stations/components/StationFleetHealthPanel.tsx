import { useTranslation } from 'react-i18next'
import { AlertTriangle, Loader2, MonitorSmartphone, WifiOff } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import type { StationFleetHealth } from '../api/stationFleetService'

export interface StationFleetHealthPanelProps {
  health: StationFleetHealth | undefined
  isLoading?: boolean
  onFilterConnectivity?: (status: string) => void
}

function CountChip({
  label,
  value,
  tone = 'default',
  onClick,
}: {
  label: string
  value: number
  tone?: 'default' | 'warn' | 'danger' | 'ok'
  onClick?: () => void
}) {
  const toneClass =
    tone === 'danger'
      ? 'border-red-300 bg-red-50 text-red-900'
      : tone === 'warn'
        ? 'border-amber-300 bg-amber-50 text-amber-950'
        : tone === 'ok'
          ? 'border-emerald-300 bg-emerald-50 text-emerald-950'
          : 'bg-muted/40'

  const content = (
    <div className={`rounded-lg border px-2.5 py-2 ${toneClass}`}>
      <p className="text-[11px] text-muted-foreground">{label}</p>
      <p className="text-lg font-semibold tabular-nums">{value}</p>
    </div>
  )

  if (!onClick) return content
  return (
    <button type="button" className="text-left" onClick={onClick}>
      {content}
    </button>
  )
}

export function StationFleetHealthPanel({
  health,
  isLoading,
  onFilterConnectivity,
}: StationFleetHealthPanelProps) {
  const { t } = useTranslation('settings')
  const counts = health?.station_counts ?? {}
  const outbox = health?.outbox

  if (isLoading && !health) {
    return (
      <div className="flex justify-center rounded-xl border py-8 text-muted-foreground">
        <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
      </div>
    )
  }

  if (!health) return null

  return (
    <div className="space-y-3 rounded-xl border p-4">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <p className="flex items-center gap-1.5 text-sm font-semibold">
            <MonitorSmartphone className="h-4 w-4" aria-hidden />
            {t('attendance_stations.fleet_title', 'Estat de les estacions')}
          </p>
          <p className="text-xs text-muted-foreground">
            {t(
              'attendance_stations.fleet_hint',
              'Connexió, cua offline reportada i lockdowns. Actualització automàtica.',
            )}
          </p>
        </div>
        <Badge variant="outline" className="text-[10px] tabular-nums">
          {new Date(health.checked_at).toLocaleTimeString()}
        </Badge>
      </div>

      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4 lg:grid-cols-6">
        <CountChip
          label={t('attendance_stations.fleet_online', 'En línia')}
          value={counts.online ?? 0}
          tone="ok"
          onClick={() => onFilterConnectivity?.('online')}
        />
        <CountChip
          label={t('attendance_stations.fleet_stale', 'Inactives')}
          value={counts.stale ?? 0}
          tone="warn"
          onClick={() => onFilterConnectivity?.('stale')}
        />
        <CountChip
          label={t('attendance_stations.fleet_offline', 'Offline')}
          value={counts.offline ?? 0}
          tone="danger"
          onClick={() => onFilterConnectivity?.('offline')}
        />
        <CountChip
          label={t('attendance_stations.fleet_never', 'Mai')}
          value={counts.never_seen ?? 0}
          onClick={() => onFilterConnectivity?.('never_seen')}
        />
        <CountChip
          label={t('attendance_stations.fleet_pending_outbox', 'Cua pendent')}
          value={outbox?.pending_total ?? 0}
          tone={(outbox?.pending_total ?? 0) > 0 ? 'warn' : 'default'}
        />
        <CountChip
          label={t('attendance_stations.fleet_lockdown', 'Lockdown')}
          value={outbox?.lockdown_count ?? 0}
          tone={(outbox?.lockdown_count ?? 0) > 0 ? 'danger' : 'default'}
        />
      </div>

      {(health.offline_stations.length > 0 || health.attention_stations.length > 0) && (
        <div className="grid gap-3 md:grid-cols-2">
          {health.offline_stations.length > 0 ? (
            <div className="space-y-1.5">
              <p className="flex items-center gap-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                <WifiOff className="h-3.5 w-3.5" aria-hidden />
                {t('attendance_stations.fleet_offline_list', 'Sense connexió / stale')}
              </p>
              <ul className="max-h-40 space-y-1 overflow-y-auto text-sm">
                {health.offline_stations.slice(0, 8).map((row) => (
                  <li key={row.device_id} className="rounded-md border px-2 py-1.5">
                    <span className="font-medium">{row.name ?? row.device_id}</span>
                    <span className="ml-2 text-[11px] text-muted-foreground">
                      {row.connectivity_status}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
          {health.attention_stations.length > 0 ? (
            <div className="space-y-1.5">
              <p className="flex items-center gap-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                <AlertTriangle className="h-3.5 w-3.5" aria-hidden />
                {t('attendance_stations.fleet_attention', 'Requereixen atenció')}
              </p>
              <ul className="max-h-40 space-y-1 overflow-y-auto text-sm">
                {health.attention_stations.slice(0, 8).map((row) => (
                  <li key={row.device_id} className="rounded-md border px-2 py-1.5">
                    <span className="font-medium">{row.name ?? row.device_id}</span>
                    <span className="ml-2 text-[11px] text-muted-foreground">{row.reason}</span>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
        </div>
      )}
    </div>
  )
}
