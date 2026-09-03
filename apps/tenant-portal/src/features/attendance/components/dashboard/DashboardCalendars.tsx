import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { useTenant } from '@/contexts/TenantContext'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { firstDayColumnOffset } from '@/lib/formatDatePattern'
import { cn } from '@/lib/utils'
import {
  buildPlannerGridRows,
  fetchSchedulePlannerDays,
  getPlannerPeriodBounds,
  toLocalIsoDate,
} from '../../api/schedulePlannerService'
import { DAY_STYLE, type ResolvedDay } from '../LaborCalendarGrid'
import type { CalendarScope } from '../../hooks/useDashboardLayout'

function monthBounds(year: number, month: number) {
  const from = `${year}-${String(month + 1).padStart(2, '0')}-01`
  const last = new Date(year, month + 1, 0).getDate()
  const to = `${year}-${String(month + 1).padStart(2, '0')}-${String(last).padStart(2, '0')}`
  return { from, to }
}

function DashboardMonthMini({
  year,
  month,
  days,
  weekStartsOn,
  highlightToday,
}: {
  year: number
  month: number
  days: Record<string, ResolvedDay>
  weekStartsOn: number
  highlightToday?: boolean
}) {
  const { t } = useTranslation('attendance')
  const months = t('labor_cal.months', { returnObjects: true }) as string[]
  const monthName = Array.isArray(months) ? months[month] : String(month + 1)
  const offset = firstDayColumnOffset(year, month, weekStartsOn)
  const daysInMonth = new Date(year, month + 1, 0).getDate()
  const today = toLocalIsoDate(new Date())
  const cells: (string | null)[] = [
    ...Array.from({ length: offset }, () => null),
    ...Array.from({ length: daysInMonth }, (_, i) =>
      `${year}-${String(month + 1).padStart(2, '0')}-${String(i + 1).padStart(2, '0')}`,
    ),
  ]
  while (cells.length % 7 !== 0) cells.push(null)

  return (
    <div className="rounded-lg border bg-card p-3 shadow-sm">
      <p className="mb-2 text-center text-xs font-semibold capitalize">{monthName} {year}</p>
      <div className="grid grid-cols-7 gap-1">
        {cells.map((date, i) => {
          if (!date) return <div key={`e${i}`} className="h-4" />
          const state = days[date] ?? { date, type: 'undefined' as const, intervals: [], source: 'none' as const }
          const s = DAY_STYLE[state.type]
          const isToday = highlightToday && date === today
          return (
            <div
              key={date}
              title={state.name ?? s.label}
              className={cn(
                'h-4 w-4 rounded-[2px]',
                s.legendMark,
                isToday && 'ring-2 ring-primary ring-offset-1',
              )}
            />
          )
        })}
      </div>
    </div>
  )
}

function DashboardWeekStrip({
  dates,
  days,
}: {
  dates: string[]
  days: Record<string, ResolvedDay>
}) {
  const { t } = useTranslation('attendance')
  const dowAbbr = t('labor_cal.dow_abbr', { returnObjects: true }) as string[]
  const today = toLocalIsoDate(new Date())

  return (
    <div className="rounded-xl border bg-card p-4 shadow-sm">
      <p className="mb-3 text-sm font-semibold">{t('dashboard.week_strip', 'Setmana actual')}</p>
      <div className="grid grid-cols-7 gap-2">
        {dates.map((date) => {
          const d = new Date(`${date}T12:00:00`)
          const dow = Array.isArray(dowAbbr) ? dowAbbr[(d.getDay() + 6) % 7] : ''
          const state = days[date] ?? { date, type: 'undefined' as const, intervals: [], source: 'none' as const }
          const s = DAY_STYLE[state.type]
          return (
            <div
              key={date}
              className={cn(
                'rounded-lg border p-2 text-center',
                date === today && 'ring-2 ring-primary',
              )}
            >
              <p className="text-[10px] font-medium uppercase text-muted-foreground">{dow}</p>
              <p className="text-sm font-semibold tabular-nums">{date.slice(8, 10)}</p>
              <div className={cn('mx-auto mt-1 h-3 w-3 rounded-sm', s.legendMark)} />
            </div>
          )
        })}
      </div>
    </div>
  )
}

interface DashboardCalendarsProps {
  scope: CalendarScope
  showPrev: boolean
  showCurrent: boolean
  showNext: boolean
  showWeek: boolean
}

export function DashboardCalendars({
  scope,
  showPrev,
  showCurrent,
  showNext,
  showWeek,
}: DashboardCalendarsProps) {
  const { t } = useTranslation('attendance')
  const { selectedSiteId, activeTenant, activeSite } = useTenant()
  const { weekStartsOn } = useCalendarDisplaySettings()

  const anchor = new Date()
  const year = anchor.getFullYear()
  const month = anchor.getMonth()

  const range = useMemo(() => {
    const prev = month === 0 ? { y: year - 1, m: 11 } : { y: year, m: month - 1 }
    const next = month === 11 ? { y: year + 1, m: 0 } : { y: year, m: month + 1 }
    const from = monthBounds(prev.y, prev.m).from
    const to = monthBounds(next.y, next.m).to
    return { prev, current: { y: year, m: month }, next, from, to }
  }, [year, month])

  const weekDates = useMemo(
    () => getPlannerPeriodBounds(anchor, 'week', weekStartsOn).dates,
    [anchor, weekStartsOn],
  )

  const tenantLabel = activeTenant?.name ?? t('schedule_planner.ref_tenant', 'Empresa')
  const siteLabel = activeSite?.name ?? t('schedule_planner.ref_site', 'Local')

  const { data: plannerDays = [] } = useQuery({
    queryKey: ['dashboard-calendar', selectedSiteId, scope, range.from, range.to],
    queryFn: async () => {
      if (!selectedSiteId) return []
      return fetchSchedulePlannerDays(selectedSiteId, range.from, range.to)
    },
    enabled: !!selectedSiteId && (showPrev || showCurrent || showNext || showWeek),
    staleTime: 120_000,
  })

  const referenceDays = useMemo(() => {
    const rows = buildPlannerGridRows(plannerDays, tenantLabel, siteLabel)
    const ref = rows.find((r) => r.scope === scope)
    return ref?.days ?? {}
  }, [plannerDays, tenantLabel, siteLabel, scope])

  if (!selectedSiteId) return null

  const hasMonth = showPrev || showCurrent || showNext

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="font-semibold">{t('dashboard.calendar_title', 'Calendari laboral')}</h2>
          <p className="text-xs text-muted-foreground">
            {scope === 'tenant'
              ? t('dashboard.calendar_tenant', 'Vista empresa')
              : t('dashboard.calendar_site', 'Vista local')}
          </p>
        </div>
        <Link
          to="/attendance-mgmt/planning/schedules"
          className="text-xs font-medium text-primary hover:underline"
        >
          {t('dashboard.calendar_open', 'Obrir planificador')}
        </Link>
      </div>
      {showWeek && (
        <DashboardWeekStrip dates={weekDates} days={referenceDays} />
      )}
      {hasMonth && (
        <div className="grid gap-3 sm:grid-cols-3">
          {showPrev && (
            <DashboardMonthMini
              year={range.prev.y}
              month={range.prev.m}
              days={referenceDays}
              weekStartsOn={weekStartsOn}
            />
          )}
          {showCurrent && (
            <DashboardMonthMini
              year={range.current.y}
              month={range.current.m}
              days={referenceDays}
              weekStartsOn={weekStartsOn}
              highlightToday
            />
          )}
          {showNext && (
            <DashboardMonthMini
              year={range.next.y}
              month={range.next.m}
              days={referenceDays}
              weekStartsOn={weekStartsOn}
            />
          )}
        </div>
      )}
    </div>
  )
}
