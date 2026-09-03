import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useDepartments } from '@/features/departments/api/useDepartments'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { useDebounce } from '@/hooks/useDebounce'
import { cn } from '@/lib/utils'
import { useAttendanceEffectiveSite } from '../hooks/useAttendanceEffectiveSite'
import { useAttendanceAllSitesFallbackToast } from '../hooks/useAttendanceAllSitesFallbackToast'
import { DAY_STYLE } from '../components/LaborCalendarGrid'
import {
  applyPlannerFilters,
  buildActualsLookup,
  DEFAULT_PLANNER_FILTERS,
  type PlannerFilters,
} from '../api/schedulePlannerFilters'
import {
  fiscalWeekNumber,
  getPlannerPeriodBounds,
  weekBounds,
} from '../api/schedulePlannerService'
import { useCalendarGroups, sanitizeOptionalUuid } from '../api/useLaborCalendar'
import { DiscrepancyLegend } from '../components/schedule-planner/ScheduleDiscrepancyBadge'
import { SchedulePlannerFilters } from '../components/schedule-planner/SchedulePlannerFilters'
import { SchedulePlannerGrid } from '../components/schedule-planner/SchedulePlannerGrid'
import { SchedulePlannerToolbar } from '../components/schedule-planner/SchedulePlannerToolbar'
import type { PlannerDataMode, PlannerViewMode } from '../components/schedule-planner/SchedulePlannerToolbar'
import { ScheduleYearGrid } from '../components/schedule-planner/ScheduleYearGrid'
import { useSchedulePlannerActuals, useSchedulePlannerDays } from '../components/schedule-planner/useSchedulePlannerData'

const PERIOD_DEBOUNCE_MS = 300

function formatMonthLabel(year: number, month: number, months: string[]): string {
  return `${months[month] ?? ''} ${year}`
}

function formatPeriodLabel(
  anchor: Date,
  viewMode: PlannerViewMode,
  weekStartsOn: number,
  months: string[],
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string,
): string {
  if (viewMode === 'week') {
    const { from, to } = weekBounds(anchor, weekStartsOn)
    const end = new Date(`${to}T12:00:00`)
    const weekNum = fiscalWeekNumber(anchor, weekStartsOn)
    const rangeLabel = `${from.slice(8, 10)}/${from.slice(5, 7)} – ${end.toISOString().slice(8, 10)}/${end.toISOString().slice(5, 7)}`
    return t('schedule_planner.week_label', 'Setmana {{week}} · {{range}}', {
      week: weekNum,
      range: rangeLabel,
    })
  }
  if (viewMode === 'year') {
    return String(anchor.getFullYear())
  }
  return formatMonthLabel(anchor.getFullYear(), anchor.getMonth(), months)
}

export function SchedulePlannerPage() {
  const { t } = useTranslation('attendance')
  const { activeRole, activeTenant } = useTenant()
  const { effectiveSiteId, effectiveSite } = useAttendanceEffectiveSite()
  useAttendanceAllSitesFallbackToast()
  const isManager = activeRole === 'owner' || activeRole === 'manager'

  const [anchor, setAnchor] = useState(() => new Date())
  const debouncedAnchor = useDebounce(anchor, PERIOD_DEBOUNCE_MS)
  const [viewMode, setViewMode] = useState<PlannerViewMode>('month')
  const [dataMode, setDataMode] = useState<PlannerDataMode>('planned')
  const [filters, setFilters] = useState<PlannerFilters>(DEFAULT_PLANNER_FILTERS)

  const { data: departments = [] } = useDepartments()
  const { data: calendarGroups = [] } = useCalendarGroups(sanitizeOptionalUuid(effectiveSiteId))
  const { weekStartsOn } = useCalendarDisplaySettings()

  const months = t('labor_cal.months', { returnObjects: true }) as string[]
  const monthList = Array.isArray(months) ? months : []

  const periodLabel = useMemo(
    () => formatPeriodLabel(anchor, viewMode, weekStartsOn, monthList, t),
    [anchor, viewMode, weekStartsOn, monthList, t],
  )

  const displayBounds = useMemo(
    () => getPlannerPeriodBounds(anchor, viewMode, weekStartsOn),
    [anchor, viewMode, weekStartsOn],
  )

  const queryBounds = useMemo(
    () => getPlannerPeriodBounds(debouncedAnchor, viewMode, weekStartsOn),
    [debouncedAnchor, viewMode, weekStartsOn],
  )

  const { dates, year } = displayBounds
  const { from, to } = queryBounds

  const isPeriodPending = debouncedAnchor.getTime() !== anchor.getTime()
  const dataAligned =
    queryBounds.from === displayBounds.from && queryBounds.to === displayBounds.to

  const tenantLabel = activeTenant?.name ?? t('schedule_planner.ref_tenant', 'Empresa')
  const siteLabel = effectiveSite?.name ?? t('schedule_planner.ref_site', 'Local')

  const needsActuals =
    viewMode === 'year' || (viewMode === 'week' && dataMode !== 'planned')

  const { data: rows = [], isLoading, isFetching: isDaysFetching } = useSchedulePlannerDays(
    effectiveSiteId,
    from,
    to,
    tenantLabel,
    siteLabel,
  )

  const { data: actuals = [], isLoading: actualsLoading, isFetching: isActualsFetching } =
    useSchedulePlannerActuals(effectiveSiteId, from, to, needsActuals)

  const actualsLoaded = needsActuals && !actualsLoading
  const actualsLookup = useMemo(() => buildActualsLookup(actuals), [actuals])

  const departmentOptions = useMemo(
    () => departments.flatMap((d) => (d.id && d.name ? [{ id: d.id, name: d.name }] : [])),
    [departments],
  )

  const departmentNames = useMemo(
    () => new Map(departmentOptions.map((d) => [d.id, d.name])),
    [departmentOptions],
  )

  const groupNames = useMemo(
    () => new Map(
      calendarGroups.flatMap((g) => (g.id && g.name ? [[g.id, g.name] as const] : [])),
    ),
    [calendarGroups],
  )

  const filteredRows = useMemo(
    () => applyPlannerFilters(
      rows,
      dates,
      filters,
      actualsLookup,
      departmentNames,
      groupNames,
      actualsLoaded,
      t('schedule_planner.group_unassigned', 'Sense assignar'),
      departmentOptions.map((d) => d.id),
      calendarGroups.flatMap((g) => (g.id ? [g.id] : [])),
    ),
    [rows, dates, filters, actualsLookup, departmentNames, groupNames, actualsLoaded, departmentOptions, calendarGroups, t],
  )

  const cellVariant = viewMode === 'week' ? 'expanded' : 'compact'
  const showDiscrepancyLegend =
    actualsLoaded && (viewMode === 'year' || (viewMode === 'week' && dataMode === 'compare'))

  const isRefreshing = isPeriodPending || isDaysFetching || (needsActuals && isActualsFetching)
  const showInitialLoading = isLoading && filteredRows.length === 0
  const showStaleOverlay = isRefreshing && !showInitialLoading && !dataAligned

  function shiftPeriod(delta: number) {
    setAnchor((prev) => {
      const d = new Date(prev)
      if (viewMode === 'week') d.setDate(d.getDate() + delta * 7)
      else if (viewMode === 'year') d.setFullYear(d.getFullYear() + delta)
      else d.setMonth(d.getMonth() + delta)
      return d
    })
  }

  function handleMonthClick(month: number) {
    const d = new Date(anchor)
    d.setMonth(month)
    d.setDate(1)
    setAnchor(d)
    setViewMode('month')
  }

  function handleFilterChange(patch: Partial<PlannerFilters>) {
    setFilters((prev) => ({ ...prev, ...patch }))
  }

  if (!isManager) {
    return (
      <div className="py-16 text-center text-muted-foreground">
        {t('schedule_planner.no_permission', 'No tens permisos per accedir al planificador d\'horaris')}
      </div>
    )
  }

  if (!effectiveSiteId) {
    return (
      <p className="text-center text-sm text-muted-foreground">
        {t('schedule_planner.no_site', 'Selecciona un centre per veure els horaris')}
      </p>
    )
  }

  return (
    <div className="space-y-4 p-1">
      <div>
        <h2 className="text-lg font-semibold">{t('schedule_planner.title', 'Planificador d\'horaris')}</h2>
        <p className="text-sm text-muted-foreground">
          {t('schedule_planner.subtitle', 'Patró laboral resolt per empleat (calendari legal/RRHH)')}
        </p>
      </div>

      <SchedulePlannerToolbar
        viewMode={viewMode}
        onViewModeChange={(mode) => {
          setViewMode(mode)
          if (mode !== 'week' && dataMode !== 'planned') setDataMode('planned')
        }}
        dataMode={dataMode}
        onDataModeChange={setDataMode}
        anchor={anchor}
        months={monthList}
        periodLabel={periodLabel}
        isRefreshing={isRefreshing}
        onAnchorChange={setAnchor}
        onPrev={() => shiftPeriod(-1)}
        onNext={() => shiftPeriod(1)}
        onToday={() => setAnchor(new Date())}
      />

      <SchedulePlannerFilters
        filters={filters}
        onChange={handleFilterChange}
        departments={departmentOptions}
        calendarGroups={calendarGroups}
        showDiscrepancyFilter={needsActuals}
      />

      <div className="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-muted-foreground">
        {(['work', 'holiday', 'vacation', 'undefined'] as const).map((type) => {
          const s = DAY_STYLE[type]
          return (
            <div key={type} className="flex items-center gap-2">
              <span className={`inline-block h-3.5 w-3.5 shrink-0 rounded-sm ${s.legendMark}`} aria-hidden />
              <span>{t(`labor_cal.type_${type}`, s.label)}</span>
            </div>
          )
        })}
      </div>

      {showDiscrepancyLegend && <DiscrepancyLegend />}

      <div
        className={cn(
          'transition-opacity duration-150',
          showStaleOverlay && 'opacity-60',
        )}
      >
        {viewMode === 'year' ? (
          <ScheduleYearGrid
            year={year}
            rows={filteredRows}
            isLoading={showInitialLoading}
            actuals={actualsLoaded ? actualsLookup : undefined}
            onMonthClick={handleMonthClick}
          />
        ) : (
          <SchedulePlannerGrid
            rows={filteredRows}
            dates={dates}
            isLoading={showInitialLoading}
            cellVariant={cellVariant}
            dataMode={dataMode}
            actuals={actualsLoaded ? actualsLookup : undefined}
          />
        )}
      </div>
    </div>
  )
}
