import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { AlertCircle, AlertTriangle, CheckCircle, Clock, Info } from 'lucide-react'
import type { TimePunch } from '../api/attendanceService'
import type { ResolvedWorkDay } from '../api/workDayResolveService'
import { formatDayScheduleLabel, isWorkLaborDay } from '../api/workDayResolveService'
import type { CurrentPunchStatus } from '../utils/punchProfileUi'
import {
  computeWorkScheduleStatus,
  type WorkScheduleStatusKind,
} from '../utils/workScheduleStatus'

interface WorkScheduleStatusCardProps {
  schedule: ResolvedWorkDay | null
  punches: TimePunch[]
  presenceStatus: CurrentPunchStatus
  nowMs?: number
  className?: string
}

const KIND_STYLES: Record<
  WorkScheduleStatusKind,
  { border: string; bg: string; title: string; icon: typeof CheckCircle }
> = {
  success: {
    border: 'border-emerald-200',
    bg: 'bg-emerald-50',
    title: 'text-emerald-900',
    icon: CheckCircle,
  },
  warning: {
    border: 'border-amber-200',
    bg: 'bg-amber-50',
    title: 'text-amber-900',
    icon: AlertTriangle,
  },
  error: {
    border: 'border-red-200',
    bg: 'bg-red-50',
    title: 'text-red-900',
    icon: AlertCircle,
  },
  info: {
    border: 'border-sky-200',
    bg: 'bg-sky-50',
    title: 'text-sky-900',
    icon: Info,
  },
}

function formatLastPunch(punch: TimePunch | null, locale: string): string | null {
  if (!punch?.occurred_at) return null
  const time = new Date(punch.occurred_at).toLocaleTimeString(locale, {
    hour: '2-digit',
    minute: '2-digit',
  })
  const type = punch.punch_type ?? 'punch'
  return `${time} · ${type}`
}

export function WorkScheduleStatusCard({
  schedule,
  punches,
  presenceStatus,
  nowMs,
  className = '',
}: WorkScheduleStatusCardProps) {
  const { t, i18n } = useTranslation('attendance')
  const now = useMemo(() => new Date(nowMs ?? Date.now()), [nowMs])
  const overnightSuffix = t('labor_cal.overnight_suffix', ' (+1)')

  const scheduleDetail = useMemo(() => {
    if (!schedule || !isWorkLaborDay(schedule) || schedule.intervals.length === 0) return undefined
    return formatDayScheduleLabel(schedule, overnightSuffix)
  }, [schedule, overnightSuffix])

  const status = useMemo(
    () =>
      computeWorkScheduleStatus({
        schedule: schedule
          ? {
              dayType: schedule.dayType,
              laborDayType: schedule.laborDayType,
              intervals: schedule.intervals,
              holidayName: schedule.holidayName,
              isAbsence: schedule.isAbsence,
            }
          : null,
        punches,
        presenceStatus,
        now,
        scheduleDetail,
      }),
    [schedule, punches, presenceStatus, now, scheduleDetail],
  )

  const lastPunch = punches.length > 0 ? punches[punches.length - 1]! : null
  const lastPunchLabel = formatLastPunch(lastPunch, i18n.language)

  if (!status) return null

  const styles = KIND_STYLES[status.kind]
  const Icon = styles.icon

  const title = t(status.titleKey, status.titleDefault)
  const description = t(
    status.descriptionKey,
    status.descriptionDefault,
    status.descriptionParams,
  )

  return (
    <div
      className={`rounded-xl border p-4 ${styles.border} ${styles.bg} ${className}`}
      role="status"
      aria-live="polite"
    >
      <div className="flex items-start gap-3">
        <Icon className={`mt-0.5 h-5 w-5 shrink-0 ${styles.title}`} aria-hidden />
        <div className="min-w-0 flex-1 space-y-1">
          <p className={`text-sm font-semibold ${styles.title}`}>{title}</p>
          <p className="text-sm text-foreground/80">{description}</p>
          {scheduleDetail && (
            <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
              <Clock className="h-3.5 w-3.5 shrink-0" aria-hidden />
              <span>{scheduleDetail}</span>
            </p>
          )}
          {lastPunchLabel && (
            <p className="text-xs text-muted-foreground">
              {t('work_status.last_punch', 'Últim fitxatge')}: {lastPunchLabel}
            </p>
          )}
        </div>
      </div>
    </div>
  )
}
