import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { CalendarDays, ChevronLeft, ChevronRight } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useAttendanceEffectiveSite } from '../../hooks/useAttendanceEffectiveSite'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { Button } from '@/components/ui/button'
import { PillToggleGroup } from '@/components/ui/pill-toggle-group'
import { firstDayColumnOffset } from '@/lib/formatDatePattern'
import { cn } from '@/lib/utils'
import {
  buildPlannerGridRows,
  fetchSchedulePlannerDays,
  fiscalWeekNumber,
  getPlannerPeriodBounds,
  weekBounds,
  toLocalIsoDate,
} from '../../api/schedulePlannerService'
import { formatIntervalsList, formatWorkDuration, totalWorkMinutes } from '../../api/workIntervals'
import { DAY_STYLE, type ResolvedDay } from '../LaborCalendarGrid'
import type {
  CalendarMonthPanels,
  CalendarScope,
  DashboardCalendarView,
} from '../../hooks/useDashboardLayout'

function monthBounds(year: number, month: number) {
  const from = `${year}-${String(month + 1).padStart(2, '0')}-01`
  const last = new Date(year, month + 1, 0).getDate()
  const to = `${year}-${String(month + 1).padStart(2, '0')}-${String(last).padStart(2, '0')}`
  return { from, to }
}

interface DashboardCalendarWidgetProps {
  scope: CalendarScope
  view: DashboardCalendarView
  anchorIso: string
  monthPanels: CalendarMonthPanels
  onViewChange: (view: DashboardCalendarView) => void
  onShiftPeriod: (delta: number) => void
  onGoToday: () => void
}

export function DashboardCalendarWidget({
  scope,
  view,
  anchorIso,
  monthPanels,
  onViewChange,
  onShiftPeriod,
  onGoToday,
}: DashboardCalendarWidgetProps) {
  const { t } = useTranslation('attendance')
  const { activeTenant } = useTenant()
  const { effectiveSiteId, effectiveSite } = useAttendanceEffectiveSite()
  const { weekStartsOn } = useCalendarDisplaySettings()

  const anchor = useMemo(() => new Date(`${anchorIso}T12:00:00`), [anchorIso])
  const today = toLocalIsoDate(new Date())
  const months = t('labor_cal.months', { returnObjects: true }) as string[]
  const monthList = Array.isArray(months) ? months : []
  const dowAbbr = t('labor_cal.dow_abbr', { returnObjects: true }) as string[]
  const overnightSuffix = t('labor_cal.overnight_suffix', ' (+1)')

  const tenantLabel = activeTenant?.name ?? t('schedule_planner.ref_tenant', 'Empresa')
  const siteLabel = effectiveSite?.name ?? t('schedule_planner.ref_site', 'Local')
  const scopeLabel = scope === 'tenant' ? tenantLabel : siteLabel

  const visibleMonths = useMemo(() => {
    const y = anchor.getFullYear()
    const m = anchor.getMonth()
    const result: { year: number; month: number }[] = []
    if (monthPanels.prev) {
      const d = new Date(y, m - 1, 1)
      result.push({ year: d.getFullYear(), month: d.getMonth() })
    }
    if (monthPanels.current) {
      result.push({ year: y, month: m })
    }
    if (monthPanels.next) {
      const d = new Date(y, m + 1, 1)
      result.push({ year: d.getFullYear(), month: d.getMonth() })
    }
    if (result.length === 0) result.push({ year: y, month: m })
    return result
  }, [anchor, monthPanels])

  const range = useMemo(() => {
    if (view === 'week') {
      const { from, to, dates } = getPlannerPeriodBounds(anchor, 'week', weekStartsOn)
      return { from, to, dates }
    }
    const first = visibleMonths[0]
    const last = visibleMonths[visibleMonths.length - 1]
    const from = monthBounds(first.year, first.month).from
    const to = monthBounds(last.year, last.month).to
    return { from, to, dates: [] as string[] }
  }, [anchor, view, weekStartsOn, visibleMonths])

  const weekLabel = useMemo(() => {
    const { from, to } = weekBounds(anchor, weekStartsOn)
    const weekNum = fiscalWeekNumber(anchor, weekStartsOn)
    const end = new Date(`${to}T12:00:00`)
    const rangeLabel = `${from.slice(8, 10)}/${from.slice(5, 7)} – ${end.toISOString().slice(8, 10)}/${end.toISOString().slice(5, 7)}`
    return t('schedule_planner.week_label', 'Setmana {{week}} · {{range}}', { week: weekNum, range: rangeLabel })
  }, [anchor, weekStartsOn, t])

  const { data: plannerDays = [] } = useQuery({
    queryKey: ['dashboard-calendar', effectiveSiteId, scope, range.from, range.to],
    queryFn: async () => {
      if (!effectiveSiteId) return []
      return fetchSchedulePlannerDays(effectiveSiteId, range.from, range.to)
    },
    enabled: !!effectiveSiteId,
    staleTime: 120_000,
  })

  const referenceDays = useMemo(() => {
    const rows = buildPlannerGridRows(plannerDays, tenantLabel, siteLabel)
    const ref = rows.find((r) => r.scope === scope)
    return ref?.days ?? {}
  }, [plannerDays, tenantLabel, siteLabel, scope])

  if (!effectiveSiteId) return null

  return (
    <div className="flex h-full flex-col overflow-hidden rounded-xl border bg-card shadow-sm">
      <div className="flex items-center justify-between gap-3 border-b px-4 py-3">
        <h2 className="min-w-0 truncate font-semibold">
          {t('dashboard.calendar_title_named', 'Calendari laboral ({{name}})', { name: scopeLabel })}
        </h2>
        <PillToggleGroup
          value={view}
          options={[
            { value: 'week' as const, label: t('dashboard.calendar_view_week', 'Setmana') },
            { value: 'month' as const, label: t('dashboard.calendar_view_month', 'Mes') },
          ]}
          onChange={onViewChange}
        />
      </div>

      <div className="flex flex-wrap items-center justify-between gap-2 border-b px-4 py-2">
        <div className="flex items-center gap-1">
          <Button type="button" variant="ghost" size="icon" className="h-7 w-7" onClick={() => onShiftPeriod(-1)}>
            <ChevronLeft className="h-4 w-4" />
          </Button>
          <Button type="button" variant="ghost" size="icon" className="h-7 w-7" onClick={() => onShiftPeriod(1)}>
            <ChevronRight className="h-4 w-4" />
          </Button>
          <span className="text-xs font-medium tabular-nums text-muted-foreground">
            {view === 'week'
              ? weekLabel
              : visibleMonths.map(({ year, month }) => `${monthList[month] ?? month + 1} ${year}`).join(' · ')}
          </span>
        </div>
        <div className="flex items-center gap-2">
          <Button type="button" variant="outline" size="sm" className="h-7 text-xs" onClick={onGoToday}>
            {t('dashboard.calendar_today', 'Avui')}
          </Button>
          <Link
            to="/attendance-mgmt/planning/schedules"
            className="text-xs font-medium text-primary hover:underline"
          >
            {t('dashboard.calendar_open', 'Obrir planificador')}
          </Link>
        </div>
      </div>

      <div className="flex-1 overflow-auto p-4">
        {view === 'week' ? (
          <DashboardWeekView
            anchor={anchor}
            weekStartsOn={weekStartsOn}
            days={referenceDays}
            today={today}
            dowAbbr={Array.isArray(dowAbbr) ? dowAbbr : []}
            overnightSuffix={overnightSuffix}
          />
        ) : (
          <div className={cn('grid gap-4', visibleMonths.length > 1 ? 'sm:grid-cols-2 lg:grid-cols-3' : '')}>
            {visibleMonths.map(({ year, month }) => (
              <DashboardMonthView
                key={`${year}-${month}`}
                year={year}
                month={month}
                monthName={monthList[month] ?? String(month + 1)}
                days={referenceDays}
                weekStartsOn={weekStartsOn}
                today={today}
                dowAbbr={Array.isArray(dowAbbr) ? dowAbbr : []}
                overnightSuffix={overnightSuffix}
                compact={visibleMonths.length > 1}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

function DashboardWeekView({
  anchor,
  weekStartsOn,
  days,
  today,
  dowAbbr,
  overnightSuffix,
}: {
  anchor: Date
  weekStartsOn: number
  days: Record<string, ResolvedDay>
  today: string
  dowAbbr: string[]
  overnightSuffix: string
}) {
  const dates = getPlannerPeriodBounds(anchor, 'week', weekStartsOn).dates

  return (
    <div className="grid grid-cols-7 gap-1">
      {dates.map((date) => {
        const d = new Date(`${date}T12:00:00`)
        const dow = dowAbbr[(d.getDay() + 6) % 7] ?? ''
        const state = days[date] ?? { date, type: 'undefined' as const, intervals: [], source: 'none' as const }
        const s = DAY_STYLE[state.type]
        const isToday = date === today
        return (
          <div
            key={date}
            className={cn(
              'flex min-h-[4.5rem] flex-col rounded-md border p-1.5 text-center',
              s.cell,
              isToday && 'ring-2 ring-primary ring-offset-1',
            )}
            title={state.name ?? s.label}
          >
            <p className="text-[10px] font-medium uppercase opacity-80">{dow}</p>
            <p className="text-sm font-semibold tabular-nums">{date.slice(8, 10)}</p>
            {state.type === 'work' && state.intervals.length > 0 && (
              <p className="mt-auto text-[9px] leading-tight tabular-nums opacity-90">
                {formatIntervalsList(state.intervals, overnightSuffix)}
              </p>
            )}
            {state.name && state.type !== 'work' && (
              <p className="mt-auto truncate text-[9px] opacity-80">{state.name}</p>
            )}
          </div>
        )
      })}
    </div>
  )
}

function DashboardMonthView({
  year,
  month,
  monthName,
  days,
  weekStartsOn,
  today,
  dowAbbr,
  overnightSuffix,
  compact = false,
}: {
  year: number
  month: number
  monthName: string
  days: Record<string, ResolvedDay>
  weekStartsOn: number
  today: string
  dowAbbr: string[]
  overnightSuffix: string
  compact?: boolean
}) {
  const offset = firstDayColumnOffset(year, month, weekStartsOn)
  const daysInMonth = new Date(year, month + 1, 0).getDate()
  const cells: (string | null)[] = [
    ...Array.from({ length: offset }, () => null),
    ...Array.from({ length: daysInMonth }, (_, i) =>
      `${year}-${String(month + 1).padStart(2, '0')}-${String(i + 1).padStart(2, '0')}`,
    ),
  ]
  while (cells.length % 7 !== 0) cells.push(null)

  return (
    <div>
      <p className="mb-2 flex items-center justify-center gap-1.5 text-sm font-semibold capitalize">
        <CalendarDays className="h-4 w-4 text-muted-foreground" />
        {monthName} {year}
      </p>
      <div className="mb-1 grid grid-cols-7">
        {dowAbbr.map((d) => (
          <div key={d} className="py-0.5 text-center text-[9px] font-medium uppercase text-muted-foreground">
            {d}
          </div>
        ))}
      </div>
      <div className="grid grid-cols-7 border border-border">
        {cells.map((date, i) => {
          if (!date) {
            return (
              <div
                key={`e${i}`}
                className={cn('border-b border-r border-border bg-muted/20', compact ? 'min-h-[2.25rem]' : 'min-h-[2.75rem]')}
              />
            )
          }
          const state = days[date] ?? { date, type: 'undefined' as const, intervals: [], source: 'none' as const }
          const s = DAY_STYLE[state.type]
          const isToday = date === today
          const dayNum = date.slice(8, 10)
          const workMin = state.type === 'work' ? totalWorkMinutes(state.intervals) : 0
          return (
            <div
              key={date}
              title={
                state.type === 'work' && state.intervals.length > 0
                  ? formatIntervalsList(state.intervals, overnightSuffix)
                  : (state.name ?? s.label)
              }
              className={cn(
                'flex flex-col items-center justify-start border-b border-r border-border p-0.5',
                s.cell,
                compact ? 'min-h-[2.25rem]' : 'min-h-[2.75rem]',
                isToday && 'ring-2 ring-inset ring-primary',
              )}
            >
              <span className={cn('text-[10px] font-semibold tabular-nums leading-none', isToday && 'text-primary')}>
                {dayNum}
              </span>
              {workMin > 0 && (
                <span className="mt-0.5 text-[8px] font-medium leading-none tabular-nums opacity-90">
                  {formatWorkDuration(workMin)}
                </span>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
