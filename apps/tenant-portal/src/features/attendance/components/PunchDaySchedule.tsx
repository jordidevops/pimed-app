import { useTranslation } from 'react-i18next'
import { CalendarClock, Loader2 } from 'lucide-react'
import type { ResolvedWorkDay } from '../api/workDayResolveService'
import {
  formatDayScheduleLabel,
  formatWorkDayDate,
  isWorkLaborDay,
} from '../api/workDayResolveService'

interface PunchDayScheduleProps {
  today: ResolvedWorkDay | null
  isLoading: boolean
  showUpcoming: boolean
  upcomingDays: ResolvedWorkDay[]
  isUpcomingLoading: boolean
}

function dayTypeLabel(
  day: ResolvedWorkDay,
  t: (key: string, fallback: string) => string,
): string {
  if (isWorkLaborDay(day)) {
    return t('punch.schedule.work_day', 'Laboral')
  }
  if (day.holidayName) return day.holidayName
  if (day.laborDayType === 'vacation') {
    return t('punch.schedule.vacation', 'Vacances')
  }
  if (day.laborDayType === 'leave') {
    return t('punch.schedule.leave', 'Permís')
  }
  if (day.laborDayType === 'holiday' || day.dayType === 'holiday') {
    return t('punch.schedule.holiday', 'Festiu')
  }
  if (day.isAbsence) {
    return t('punch.schedule.absence', 'Absència')
  }
  return t('punch.schedule.non_working', 'No laborable')
}

function scheduleDetail(
  day: ResolvedWorkDay,
  overnightSuffix: string,
  t: (key: string, fallback: string) => string,
): string {
  if (isWorkLaborDay(day) && day.intervals.length > 0) {
    return formatDayScheduleLabel(day, overnightSuffix)
  }
  return dayTypeLabel(day, t)
}

export function PunchDaySchedule({
  today,
  isLoading,
  showUpcoming,
  upcomingDays,
  isUpcomingLoading,
}: PunchDayScheduleProps) {
  const { t } = useTranslation('attendance')
  const overnightSuffix = t('labor_cal.overnight_suffix', ' (+1)')

  if (isLoading) {
    return (
      <div className="flex items-center justify-center gap-2 py-2 text-xs text-muted-foreground">
        <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden />
        <span>{t('punch.schedule.loading', 'Carregant horari…')}</span>
      </div>
    )
  }

  if (!today) return null

  const todayIsWork = isWorkLaborDay(today)
  const todayScheduleText =
    todayIsWork && today.intervals.length > 0
      ? formatDayScheduleLabel(today, overnightSuffix)
      : null

  const tomorrow = upcomingDays[0] ?? null
  const nextWorkAfterTomorrow = upcomingDays.slice(1).find((d) => isWorkLaborDay(d)) ?? null
  const firstFutureWorkDay = upcomingDays.find((d) => isWorkLaborDay(d)) ?? null

  return (
    <div className="space-y-3 rounded-xl border border-border/60 bg-muted/30 px-4 py-3 text-sm">
      <div className="flex items-start gap-2.5">
        <CalendarClock className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" aria-hidden />
        <div className="min-w-0 flex-1 space-y-0.5">
          <p className="text-xs font-medium text-muted-foreground">
            {t('punch.schedule.today_title', 'Horari d’avui')}
          </p>
          <p className="text-foreground">
            <span className="font-medium">{dayTypeLabel(today, t)}</span>
            {todayScheduleText && (
              <span className="text-muted-foreground"> · {todayScheduleText}</span>
            )}
          </p>
        </div>
      </div>

      {showUpcoming && (
        <div className="space-y-2 border-t border-border/50 pt-3">
          {isUpcomingLoading ? (
            <p className="text-xs text-muted-foreground">
              {t('punch.schedule.loading_upcoming', 'Consultant propers dies…')}
            </p>
          ) : (
            <>
              {tomorrow && (
                <p className="text-xs text-muted-foreground">
                  <span className="font-medium text-foreground/80">
                    {t('punch.schedule.tomorrow', 'Demà')}
                  </span>
                  {' — '}
                  {scheduleDetail(tomorrow, overnightSuffix, t)}
                </p>
              )}
              {tomorrow && !isWorkLaborDay(tomorrow) && firstFutureWorkDay && (
                <p className="text-xs text-muted-foreground">
                  <span className="font-medium text-foreground/80">
                    {t('punch.schedule.next_work_day', 'Proper dia laborable')}
                  </span>
                  {' · '}
                  {formatWorkDayDate(firstFutureWorkDay.date)}
                  {' — '}
                  {scheduleDetail(firstFutureWorkDay, overnightSuffix, t)}
                </p>
              )}
              {tomorrow && isWorkLaborDay(tomorrow) && nextWorkAfterTomorrow && (
                <p className="text-xs text-muted-foreground">
                  <span className="font-medium text-foreground/80">
                    {t('punch.schedule.next_work_day', 'Proper dia laborable')}
                  </span>
                  {' · '}
                  {formatWorkDayDate(nextWorkAfterTomorrow.date)}
                  {' — '}
                  {scheduleDetail(nextWorkAfterTomorrow, overnightSuffix, t)}
                </p>
              )}
            </>
          )}
        </div>
      )}
    </div>
  )
}
