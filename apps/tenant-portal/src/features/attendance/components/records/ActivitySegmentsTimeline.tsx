import { useTranslation } from 'react-i18next'
import { Briefcase, Car, Coffee, Moon, PauseCircle } from 'lucide-react'
import type { ActivityKind, ActivitySegment } from '../../api/activitySegmentService'
import { segmentDurationMinutes } from '../../api/activitySegmentService'
import { formatDayDetailTime } from '../../api/dayDetailService'
import { formatTimesheetMinutes } from '../../api/timesheetService'

interface ActivitySegmentsTimelineProps {
  segments: ActivitySegment[]
  className?: string
}

const SEGMENT_I18N: Record<ActivityKind, { key: string; fallback: string }> = {
  WORK: { key: 'segment.kind_work', fallback: 'Treball' },
  TRAVEL: { key: 'segment.kind_travel', fallback: 'Desplaçament' },
  BREAK_PAID: { key: 'segment.kind_break_paid', fallback: 'Pausa (pagada)' },
  BREAK_UNPAID: { key: 'segment.kind_break_unpaid', fallback: 'Pausa (no pagada)' },
  OFF_DUTY: { key: 'segment.kind_off_duty', fallback: 'Fora servei' },
  STANDBY: { key: 'segment.kind_standby', fallback: 'Espera' },
}

function segmentDotColor(kind: ActivityKind): string {
  switch (kind) {
    case 'WORK':
      return 'bg-emerald-500'
    case 'TRAVEL':
      return 'bg-violet-500'
    case 'BREAK_PAID':
    case 'BREAK_UNPAID':
      return 'bg-amber-400'
    case 'STANDBY':
      return 'bg-sky-400'
    default:
      return 'bg-slate-400'
  }
}

function SegmentIcon({ kind }: { kind: ActivityKind }) {
  switch (kind) {
    case 'WORK':
      return <Briefcase className="h-4 w-4 text-emerald-600" aria-hidden />
    case 'TRAVEL':
      return <Car className="h-4 w-4 text-violet-600" aria-hidden />
    case 'BREAK_PAID':
    case 'BREAK_UNPAID':
      return <Coffee className="h-4 w-4 text-amber-600" aria-hidden />
    case 'STANDBY':
      return <PauseCircle className="h-4 w-4 text-sky-600" aria-hidden />
    default:
      return <Moon className="h-4 w-4 text-slate-500" aria-hidden />
  }
}

export function ActivitySegmentsTimeline({
  segments,
  className = '',
}: ActivitySegmentsTimelineProps) {
  const { t } = useTranslation('attendance')

  if (segments.length === 0) return null

  return (
    <section className={`rounded-xl border bg-card p-4 ${className}`}>
      <h3 className="mb-3 text-sm font-semibold">
        {t('segment.timeline_title', 'Segments d\'activitat')}
      </h3>
      <ol className="relative ml-3 space-y-3 border-l border-border">
        {segments.map((segment) => {
          const meta = SEGMENT_I18N[segment.activity_kind] ?? {
            key: 'segment.kind_unknown',
            fallback: segment.activity_kind,
          }
          const duration = segmentDurationMinutes(segment)
          const open = !segment.ended_at

          return (
            <li key={segment.id} className="ml-4">
              <span
                className={`absolute -left-1.5 flex h-3 w-3 rounded-full border-2 border-background ${segmentDotColor(segment.activity_kind)}`}
                aria-hidden
              />
              <div className="flex flex-wrap items-center gap-2">
                <SegmentIcon kind={segment.activity_kind} />
                <span className="text-sm font-medium">
                  {t(meta.key, meta.fallback)}
                </span>
                <span className="text-xs text-muted-foreground tabular-nums">
                  {formatDayDetailTime(segment.started_at)}
                  {' – '}
                  {open
                    ? t('segment.open', 'obert')
                    : formatDayDetailTime(segment.ended_at)}
                </span>
                {!open && duration > 0 && (
                  <span className="ml-auto text-sm tabular-nums text-muted-foreground">
                    {formatTimesheetMinutes(duration)}
                  </span>
                )}
              </div>
            </li>
          )
        })}
      </ol>
    </section>
  )
}
