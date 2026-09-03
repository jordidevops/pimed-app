import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ChevronDown } from 'lucide-react'
import type { TenantDayType } from '../api/useLaborCalendar'
import type { WorkInterval } from '../api/workIntervals'
import {
  formatIntervalsList,
  formatWorkDuration,
  intervalsKey,
  totalWorkMinutes,
} from '../api/workIntervals'

/** Minimal day shape for schedule filter markers (avoids circular import with LaborCalendarGrid). */
export interface ScheduleFilterDay {
  type: TenantDayType
  intervals: WorkInterval[]
  hasScopeGroupOverride?: boolean
}

export interface ScheduleFilterState {
  intervalFilterKey: string | null
  hourFilter: number | null
  mostCommonScheduleKey: string | null
  groupEditMode?: boolean
}

export function useScheduleFilters(dayMap: Map<string, ScheduleFilterDay>) {
  const [intervalFilterKey, setIntervalFilterKey] = useState<string | null>(null)
  const [hourFilter, setHourFilter] = useState<number | null>(null)

  const scheduleIndex = useMemo(() => {
    const byKey = new Map<string, { intervals: WorkInterval[]; minutes: number; count: number }>()
    for (const [, day] of dayMap) {
      if (day.type !== 'work' || day.intervals.length === 0) continue
      const key = intervalsKey(day.intervals)
      const minutes = totalWorkMinutes(day.intervals)
      const existing = byKey.get(key)
      if (existing) existing.count++
      else byKey.set(key, { intervals: day.intervals, minutes, count: 1 })
    }
    return [...byKey.entries()].sort((a, b) => b[1].count - a[1].count)
  }, [dayMap])

  const hourBuckets = useMemo(() => {
    const buckets = new Map<number, number>()
    for (const [, day] of dayMap) {
      if (day.type !== 'work') continue
      const h = Math.round(totalWorkMinutes(day.intervals) / 60)
      buckets.set(h, (buckets.get(h) ?? 0) + 1)
    }
    return [...buckets.entries()].sort((a, b) => a[0] - b[0])
  }, [dayMap])

  const mostCommonScheduleKey = scheduleIndex[0]?.[0] ?? null
  const hasActiveFilter = intervalFilterKey !== null || hourFilter !== null

  function clearFilters() {
    setIntervalFilterKey(null)
    setHourFilter(null)
  }

  function toggleIntervalFilter(key: string) {
    setHourFilter(null)
    setIntervalFilterKey((prev) => (prev === key ? null : key))
  }

  function toggleHourFilter(hours: number) {
    setIntervalFilterKey(null)
    setHourFilter((prev) => (prev === hours ? null : hours))
  }

  function filterState(groupEditMode?: boolean): ScheduleFilterState {
    return { intervalFilterKey, hourFilter, mostCommonScheduleKey, groupEditMode }
  }

  return {
    scheduleIndex,
    hourBuckets,
    intervalFilterKey,
    hourFilter,
    hasActiveFilter,
    mostCommonScheduleKey,
    clearFilters,
    toggleIntervalFilter,
    toggleHourFilter,
    filterState,
  }
}

function dayMatchesScheduleFilters(state: ScheduleFilterDay, filters: ScheduleFilterState): boolean {
  const active = filters.intervalFilterKey !== null || filters.hourFilter !== null
  if (!active) return true
  if (state.type !== 'work' || state.intervals.length === 0) return false
  if (filters.intervalFilterKey && intervalsKey(state.intervals) !== filters.intervalFilterKey) return false
  if (filters.hourFilter !== null) {
    const hours = Math.round(totalWorkMinutes(state.intervals) / 60)
    if (hours !== filters.hourFilter) return false
  }
  return true
}

/** Visual markers for calendar day cells (dots, rings, dimming). */
export function dayScheduleMarkers(state: ScheduleFilterDay, filters: ScheduleFilterState): string {
  const markers: string[] = []
  const active = filters.intervalFilterKey !== null || filters.hourFilter !== null
  const matches = dayMatchesScheduleFilters(state, filters)

  if (filters.groupEditMode && state.hasScopeGroupOverride) {
    markers.push('ring-1 ring-primary/70')
  }

  if (state.type === 'work' && state.intervals.length > 0) {
    const key = intervalsKey(state.intervals)
    if (active && matches) {
      markers.push('ring-2 ring-violet-600')
    } else if (!active && filters.mostCommonScheduleKey && key !== filters.mostCommonScheduleKey) {
      markers.push(
        'after:content-[""] after:absolute after:top-0.5 after:right-0.5 after:h-1.5 after:w-1.5 after:rounded-full after:bg-violet-600',
      )
    }
  }

  if (active && !matches) markers.push('opacity-35')
  return markers.join(' ')
}

export function ScheduleFilterBar({
  scheduleIndex,
  hourBuckets,
  intervalFilterKey,
  hourFilter,
  overnightSuffix,
  onClear,
  onToggleInterval,
  onToggleHour,
}: {
  scheduleIndex: [string, { intervals: WorkInterval[]; minutes: number; count: number }][]
  hourBuckets: [number, number][]
  intervalFilterKey: string | null
  hourFilter: number | null
  overnightSuffix: string
  onClear: () => void
  onToggleInterval: (key: string) => void
  onToggleHour: (hours: number) => void
}) {
  const { t } = useTranslation('attendance')
  const [expanded, setExpanded] = useState(false)

  if (scheduleIndex.length === 0 && hourBuckets.length === 0) return null

  const allInactive = intervalFilterKey === null && hourFilter === null
  const hasActiveFilter = !allInactive

  const filterContent = (
    <>
      <div className="flex flex-wrap gap-1.5">
        <button
          type="button"
          onClick={onClear}
          className={`rounded-full px-2.5 py-0.5 text-[11px] border ${allInactive ? 'bg-primary text-primary-foreground border-primary' : 'hover:bg-muted'}`}
        >
          {t('labor_cal.schedule_filter_all', 'Tots')}
        </button>
        {scheduleIndex.map(([key, info]) => (
          <button
            key={key}
            type="button"
            onClick={() => onToggleInterval(key)}
            className={`rounded-full px-2.5 py-0.5 text-[11px] border tabular-nums ${intervalFilterKey === key ? 'bg-violet-600 text-white border-violet-600' : 'hover:bg-muted'}`}
            title={t('labor_cal.schedule_filter_count', '{{count}} dies', { count: info.count })}
          >
            {formatIntervalsList(info.intervals, overnightSuffix)} · {formatWorkDuration(info.minutes)}
          </button>
        ))}
        {hourBuckets.length > 0 && scheduleIndex.length > 0 && (
          <span className="self-center text-[10px] text-muted-foreground px-1">|</span>
        )}
        {hourBuckets.map(([hours, count]) => (
          <button
            key={`h-${hours}`}
            type="button"
            onClick={() => onToggleHour(hours)}
            className={`rounded-full px-2.5 py-0.5 text-[11px] border tabular-nums ${hourFilter === hours ? 'bg-amber-600 text-white border-amber-600' : 'hover:bg-muted'}`}
            title={t('labor_cal.schedule_filter_hours_count', '{{count}} dies · {{hours}} h totals', { count, hours })}
          >
            {hours} h
          </button>
        ))}
      </div>
      <p className="text-[10px] text-muted-foreground">
        {t(
          'labor_cal.schedule_filter_hint',
          'Franges: horari exacte. Hores: total diari (independent de les franges). Sense filtre actiu, els dies amb horari diferent del més habitual es marquen amb un punt violeta.',
        )}
      </p>
    </>
  )

  return (
    <div className="rounded-lg border bg-muted/20">
      <button
        type="button"
        className="lg:hidden flex w-full items-center gap-2 p-3 text-left"
        onClick={() => setExpanded((v) => !v)}
        aria-expanded={expanded}
      >
        <span className="text-xs font-medium text-muted-foreground flex-1">
          {t('labor_cal.schedule_filters_title', 'Filtrar per horari')}
        </span>
        {hasActiveFilter && (
          <span className="text-[10px] rounded-full bg-primary/15 text-primary px-2 py-0.5 font-medium">
            {t('labor_cal.schedule_filter_active', 'Actiu')}
          </span>
        )}
        <ChevronDown className={`h-4 w-4 shrink-0 text-muted-foreground transition-transform ${expanded ? 'rotate-180' : ''}`} />
      </button>
      <div className={`space-y-2 px-3 pb-3 ${expanded ? 'block' : 'hidden'} lg:block`}>
        <p className="hidden lg:block text-xs font-medium text-muted-foreground pt-3 lg:pt-0">
          {t('labor_cal.schedule_filters_title', 'Filtrar per horari')}
        </p>
        {filterContent}
      </div>
    </div>
  )
}
