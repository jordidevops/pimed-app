import { useTranslation } from 'react-i18next'
import { Clock } from 'lucide-react'
import type { TimePunch } from '../api/attendanceService'
import type { LocalAttendanceOp } from '../db/attendanceDb'
import { TIMELINE_TYPE_I18N_KEY, type ExtendedPunchType } from '../utils/punchProfileUi'
import { PunchTypeIcon } from './PunchTypeIcon'

interface DailyTimelineProps {
  punches: TimePunch[]
  pendingOps?: LocalAttendanceOp[]
  className?: string
  title?: string
  emptyMessage?: string
}

function formatTime(iso: string | null | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString('ca-ES', { hour: '2-digit', minute: '2-digit' })
}

function punchLabel(
  punchType: string,
  pauseType: string | null | undefined,
  t: (key: string, fallback: string) => string,
): string {
  const key = TIMELINE_TYPE_I18N_KEY[punchType as ExtendedPunchType]
  if (key) {
    const base = t(key, punchType)
    if (punchType === 'break_start' && pauseType) return `${base} (${pauseType})`
    return base
  }
  return punchType
}

function punchDotColor(punchType: string): string {
  switch (punchType) {
    case 'in':
      return 'bg-emerald-500'
    case 'break_start':
    case 'break_end':
      return 'bg-amber-400'
    case 'day_start':
      return 'bg-sky-500'
    case 'travel_start':
    case 'travel_end':
      return 'bg-violet-500'
    case 'day_end':
      return 'bg-slate-500'
    default:
      return 'bg-slate-400'
  }
}

function PunchTimelineIcon({ punchType }: { punchType: string }) {
  return <PunchTypeIcon punchType={punchType} className="h-4 w-4" />
}

export function DailyTimeline({
  punches,
  pendingOps = [],
  className = '',
  title,
  emptyMessage,
}: DailyTimelineProps) {
  const { t } = useTranslation('attendance')
  const heading = title ?? t('timeline.title', 'Avui')

  if (punches.length === 0 && pendingOps.length === 0) {
    return (
      <div className={`py-8 text-center text-sm text-muted-foreground ${className}`}>
        {emptyMessage ?? t('timeline.empty', 'Encara no hi ha fitxatges avui')}
      </div>
    )
  }

  return (
    <div className={`space-y-2 ${className}`}>
      <h3 className="px-1 text-sm font-semibold uppercase tracking-wide text-muted-foreground">
        {heading}
      </h3>
      <ol className="relative ml-3 space-y-3 border-l border-border">
        {punches.map((punch) => {
          const pt = punch.punch_type ?? 'in'
          const pauseType = (punch as TimePunch & { pause_type?: string }).pause_type
          return (
            <li key={punch.id} className="ml-4">
              <span
                className={`absolute -left-1.5 flex h-3 w-3 rounded-full border-2 border-background ${punchDotColor(pt)}`}
                aria-hidden
              />
              <div className="flex items-center gap-2">
                <PunchTimelineIcon punchType={pt} />
                <span className="text-sm font-medium">{punchLabel(pt, pauseType, t)}</span>
                <time
                  className="ml-auto tabular-nums text-sm text-muted-foreground"
                  dateTime={punch.occurred_at ?? undefined}
                >
                  {formatTime(punch.occurred_at)}
                </time>
              </div>
              {(punch.location_name_snapshot || punch.device_name_snapshot) && (
                <p className="ml-6 mt-0.5 text-xs text-muted-foreground">
                  {[punch.location_name_snapshot, punch.device_name_snapshot]
                    .filter(Boolean)
                    .join(' · ')}
                </p>
              )}
              {(punch.anomaly_codes?.length ?? 0) > 0 && (
                <p className="ml-6 mt-0.5 text-xs text-amber-600">⚠ {punch.anomaly_codes!.join(', ')}</p>
              )}
            </li>
          )
        })}
        {pendingOps.map((op) => (
          <li key={op.client_op_id} className="ml-4 opacity-60">
            <span
              className="absolute -left-1.5 flex h-3 w-3 rounded-full border-2 border-background bg-amber-400"
              aria-hidden
            />
            <div className="flex items-center gap-2">
              <Clock className="h-4 w-4 text-amber-500" aria-hidden />
              <span className="text-sm font-medium">{punchLabel(op.punch_type, op.pause_type, t)}</span>
              <span className="ml-1 text-xs italic text-amber-600">
                {op.status === 'quarantined'
                  ? t('punch.quarantined_label', 'Error de sincronització')
                  : t('timeline.pending_sync', 'Pendent de sincronitzar')}
              </span>
              <time className="ml-auto tabular-nums text-sm text-muted-foreground" dateTime={op.occurred_at}>
                {formatTime(op.occurred_at)}
              </time>
            </div>
          </li>
        ))}
      </ol>
    </div>
  )
}
