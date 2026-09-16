import { useEffect, useState } from 'react'
import { ArrowRight, LogIn, LogOut, Flag, PlayCircle, Car, MapPin, Wifi, WifiOff } from 'lucide-react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAttendanceAccess } from '@/features/attendance/hooks/useAttendanceAccess'
import { useAttendanceSession } from '@/features/attendance/hooks/useAttendanceSession'
import { useAttendanceRecordPolicy } from '@/features/attendance/api/useAttendanceRecordPolicy'
import { useMyPunchSchedule } from '@/features/attendance/api/useMyPunchSchedule'
import {
  formatDayScheduleLabel,
  formatWorkDayDate,
} from '@/features/attendance/api/workDayResolveService'
import { WorkedTimeDisplay } from '@/features/attendance/components/WorkedTimeDisplay'
import {
  isLegacyInOutOnly,
  PUNCH_TYPE_DEFAULT_LABEL,
  PUNCH_TYPE_I18N_KEY,
  getPrimaryPunchAction,
  isMobileWorkProfile,
  punchHeroColorClass,
  type ExtendedPunchType,
} from '@/features/attendance/utils/punchProfileUi'
import { cn } from '@/lib/utils'

function PunchActionIcon({ type }: { type: ExtendedPunchType }) {
  const className = 'h-4 w-4'
  switch (type) {
    case 'in':
      return <LogIn className={className} aria-hidden />
    case 'out':
      return <LogOut className={className} aria-hidden />
    case 'day_start':
      return <PlayCircle className={className} aria-hidden />
    case 'day_end':
      return <Flag className={className} aria-hidden />
    case 'travel_start':
      return <Car className={className} aria-hidden />
    case 'travel_end':
      return <MapPin className={className} aria-hidden />
    default:
      return <ArrowRight className={className} aria-hidden />
  }
}

export function TodayAttendanceCard() {
  const { t, i18n } = useTranslation('attendance')
  const access = useAttendanceAccess()
  const { data: policy } = useAttendanceRecordPolicy(access.employee?.id ?? undefined)
  const workProfile = policy?.work_profile ?? 'fixed_site'
  const legacy = isLegacyInOutOnly(workProfile, policy?.policy)
  const session = useAttendanceSession({
    workProfile,
    legacyInOutOnly: legacy,
  })
  const [now, setNow] = useState(() => Date.now())
  const schedule = useMyPunchSchedule(access.employee?.id, { nowMs: now })

  useEffect(() => {
    const ms = session.currentStatus === 'working' ? 1_000 : 30_000
    const timer = window.setInterval(() => setNow(Date.now()), ms)
    return () => window.clearInterval(timer)
  }, [session.currentStatus])

  const primaryAction = getPrimaryPunchAction(
    session.dayState,
    isMobileWorkProfile(workProfile),
    legacy,
  )
  const day = schedule.showUpcoming
    ? schedule.upcoming.nextWorkDay
    : schedule.today
  const title = schedule.showUpcoming
    ? t('today_card.next_shift', 'Pròxima jornada')
    : t('today_card.today_shift', "Jornada d'avui")
  const statusTone =
    session.currentStatus === 'working'
      ? 'border-emerald-300 bg-emerald-50/70 dark:border-emerald-900 dark:bg-emerald-950/30'
      : session.currentStatus === 'on_pause'
        ? 'border-amber-300 bg-amber-50/70 dark:border-amber-900 dark:bg-amber-950/30'
        : 'border-border bg-card'
  const rawScheduleLabel = day
    ? formatDayScheduleLabel(day, t('labor_cal.overnight_suffix', ' (+1)'))
    : null
  const scheduleLabel =
    rawScheduleLabel === 'off'
      ? t('punch.schedule.non_working', 'No laborable')
      : rawScheduleLabel === 'vacation' ||
          rawScheduleLabel === 'leave' ||
          rawScheduleLabel === 'holiday'
        ? t(`punch.schedule.${rawScheduleLabel}`, rawScheduleLabel)
        : rawScheduleLabel

  if (!access.canUseAttendance) return null

  return (
    <section className={cn('rounded-2xl border p-4 shadow-sm', statusTone)}>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            {title}
          </p>
          <h2 className="mt-1 font-semibold">
            {day
              ? formatWorkDayDate(
                  day.date,
                  i18n.language?.startsWith('es')
                    ? 'es-ES'
                    : i18n.language?.startsWith('en')
                      ? 'en-US'
                      : 'ca-ES',
                )
              : t('today_card.no_schedule', 'Sense jornada planificada')}
          </h2>
          {day && (
            <p className="mt-1 text-sm text-muted-foreground">
              {scheduleLabel}
            </p>
          )}
        </div>
        <WorkedTimeDisplay
          punches={session.projectedPunches}
          status={session.currentStatus}
          nowMs={now}
          size="compact"
          align="end"
        />
      </div>

      <div className="mt-4 flex items-center justify-between gap-3">
        <div className="flex min-w-0 items-center gap-1.5 text-xs text-muted-foreground">
          {session.sync.isOnline ? (
            <Wifi className="h-3.5 w-3.5 text-emerald-600" />
          ) : (
            <WifiOff className="h-3.5 w-3.5 text-amber-600" />
          )}
          <span>
            {session.sync.isOnline
              ? t('sync.status_online', 'Connectat')
              : t('sync.status_offline', 'Sense connexió')}
          </span>
          {session.sync.pendingCount > 0 && (
            <span>· {t('sync.pending_short', '{{count}} pendents', { count: session.sync.pendingCount })}</span>
          )}
        </div>
        <Link
          to="/attendance"
          className={cn(
            'inline-flex h-9 shrink-0 items-center gap-1.5 rounded-lg px-3 text-sm font-semibold shadow-sm',
            primaryAction
              ? punchHeroColorClass(primaryAction)
              : 'bg-primary text-primary-foreground hover:bg-primary/90',
          )}
        >
          {primaryAction && <PunchActionIcon type={primaryAction} />}
          {primaryAction
            ? t(PUNCH_TYPE_I18N_KEY[primaryAction], PUNCH_TYPE_DEFAULT_LABEL[primaryAction])
            : t('today_card.open_attendance', 'Horari')}
        </Link>
      </div>
    </section>
  )
}
