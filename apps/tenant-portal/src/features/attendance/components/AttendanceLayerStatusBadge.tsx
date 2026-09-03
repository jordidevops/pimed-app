import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import {
  TIMESHEET_STATUS_CLASS,
  attendanceStatusLabelKey,
  type AttendanceStatusLayer,
} from '../api/timesheetService'

interface AttendanceStatusBadgeProps {
  status: string | null | undefined
  /** Força la capa semàntica (per defecte s'inferèix del valor). */
  layer?: AttendanceStatusLayer
  t: (key: string, fallback?: string) => string
  className?: string
  size?: 'xs' | 'sm'
}

export function AttendanceLayerStatusBadge({
  status,
  layer,
  t,
  className,
  size = 'xs',
}: AttendanceStatusBadgeProps) {
  if (!status) return <span className="text-muted-foreground">—</span>

  const labelKey = attendanceStatusLabelKey(status, layer)
  const label = labelKey ? t(labelKey, status) : status

  return (
    <Badge
      variant="outline"
      className={cn(
        size === 'xs' ? 'text-xs' : 'text-sm',
        TIMESHEET_STATUS_CLASS[status] ?? 'bg-muted text-muted-foreground',
        className,
      )}
      title={label}
    >
      {label}
    </Badge>
  )
}

/** Badges de capa A (jornada) i capa B (dia nòmina) sense barrejar semàntica. */
export function TimesheetDayLayerBadges({
  entryStatus,
  summaryStatus,
  t,
  size = 'xs',
  className,
  layout = 'row',
}: {
  entryStatus?: string | null
  summaryStatus?: string | null
  t: (key: string, fallback?: string) => string
  size?: 'xs' | 'sm'
  className?: string
  layout?: 'row' | 'col'
}) {
  const hasEntry = Boolean(entryStatus)
  const hasSummary = Boolean(summaryStatus)

  if (!hasEntry && !hasSummary) {
    return <span className="text-xs text-muted-foreground">—</span>
  }

  return (
    <div
      className={cn(
        'flex gap-1',
        layout === 'col' ? 'flex-col items-end' : 'flex-wrap items-center',
        className,
      )}
    >
      {hasEntry ? (
        <AttendanceLayerStatusBadge status={entryStatus} layer="entry" t={t} size={size} />
      ) : null}
      {hasSummary ? (
        <AttendanceLayerStatusBadge status={summaryStatus} layer="summary" t={t} size={size} />
      ) : null}
    </div>
  )
}
