/**
 * LaborCalendarGrid — visual tenant/site labor calendar editor.
 * Assigned holiday calendars are a higher-priority source than generic work/vacation patterns.
 */
import { useState, useEffect, useCallback, useRef, useMemo, type MouseEvent, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ChevronLeft, ChevronRight, CalendarDays, Settings2, X, Check,
  Building2, MapPin, ChevronDown, ChevronUp,
} from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { formatIsoDateWithPattern, firstDayColumnOffset, weekColumnOrder } from '@/lib/formatDatePattern'
import { Button } from '@/components/ui/button'
import {
  useLaborCalendarOverrides,
  useAssignedHolidays,
  useUpsertLaborCalendarDays,
  useApplyWeeklyPattern,
} from '../api/useLaborCalendar'
import type { TenantDayType, LaborCalendarOverride } from '../api/useLaborCalendar'
import type { Holiday } from '../api/shiftsService'
import {
  intervalsFromOverride,
  formatIntervalsList,
  formatInterval,
  validateWorkIntervals,
  defaultIntervals,
  totalWorkMinutes,
  formatWorkDuration,
  intervalsKey,
  WEEKDAY_JS_DOW,
  WEEKEND_JS_DOW,
  QUICK_WEEKDAY_PRESETS,
  type WorkInterval,
} from '../api/workIntervals'
import { WorkIntervalsEditor } from './WorkIntervalsEditor'
import {
  ScheduleFilterBar,
  dayScheduleMarkers,
  useScheduleFilters,
  type ScheduleFilterState,
} from './ScheduleFilterBar'
import { CalendarDayTooltip } from './CalendarDayTooltip'

export { dayScheduleMarkers, type ScheduleFilterState }

const TENANT_DAY_TYPES: TenantDayType[] = ['work', 'holiday', 'vacation', 'undefined']
/** Mon-first index → JS DOW (for i18n arrays ordered Mon…Sun) */
const MON_FIRST_JS = [1, 2, 3, 4, 5, 6, 0]

type DayStyle = {
  label: string
  cell: string
  hover: string
  ring: string
  badge: string
  legendMark: string
}

export const DAY_STYLE: Record<TenantDayType, DayStyle> = {
  work: {
    label: 'Laboral',
    cell: 'bg-emerald-200/90 border-l-[3px] border-l-emerald-700 text-emerald-950',
    hover: 'hover:bg-emerald-300/90',
    ring: 'ring-emerald-700',
    badge: 'bg-emerald-200 text-emerald-950 border border-emerald-700',
    legendMark: 'bg-emerald-600',
  },
  holiday: {
    label: 'Festiu',
    cell: 'bg-red-200/90 border-l-[3px] border-l-red-700 text-red-950 [background-image:repeating-linear-gradient(-45deg,transparent,transparent_3px,rgba(0,0,0,.06)_3px,rgba(0,0,0,.06)_6px)]',
    hover: 'hover:bg-red-300/90',
    ring: 'ring-red-700',
    badge: 'bg-red-200 text-red-950 border border-red-700',
    legendMark: 'bg-red-600',
  },
  vacation: {
    label: 'Vacances',
    cell: 'bg-sky-200/90 border-l-[3px] border-l-sky-700 text-sky-950',
    hover: 'hover:bg-sky-300/90',
    ring: 'ring-sky-700',
    badge: 'bg-sky-200 text-sky-950 border border-sky-700',
    legendMark: 'bg-sky-600',
  },
  undefined: {
    label: 'Indefinit',
    cell: 'bg-white border border-dashed border-slate-400 text-slate-700',
    hover: 'hover:bg-slate-100',
    ring: 'ring-slate-500',
    badge: 'bg-white text-slate-700 border border-dashed border-slate-400',
    legendMark: 'border border-dashed border-slate-500 bg-white',
  },
}

function toDateStr(y: number, m: number, d: number) {
  return `${y}-${String(m + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`
}

/**
 * Excel-like rectangular selection: given an anchor and a target date, selects
 * all dates whose weekday column falls between the two columns, for every week
 * row between the two dates.  Drag Mon→Fri across two weeks → Mon–Fri both weeks.
 */
export function rectDateRange(a: string, b: string, weekStartsOn: number): string[] {
  const dateA = new Date(`${a}T12:00:00`)
  const dateB = new Date(`${b}T12:00:00`)

  // Column index within the displayed week (0 = first visible column)
  function toCol(d: Date): number {
    return (d.getDay() - weekStartsOn + 7) % 7
  }

  // First day of the displayed week containing d
  function weekStart(d: Date): Date {
    const copy = new Date(d)
    copy.setDate(d.getDate() - toCol(d))
    return copy
  }

  const colA = toCol(dateA)
  const colB = toCol(dateB)
  const minCol = Math.min(colA, colB)
  const maxCol = Math.max(colA, colB)

  const wsA = weekStart(dateA)
  const wsB = weekStart(dateB)
  const wsMin = wsA <= wsB ? wsA : wsB
  const wsMax = wsA <= wsB ? wsB : wsA

  const out: string[] = []
  const cur = new Date(wsMin)
  while (cur <= wsMax) {
    for (let col = minCol; col <= maxCol; col++) {
      const d = new Date(cur)
      d.setDate(cur.getDate() + col)
      out.push(d.toISOString().slice(0, 10))
    }
    cur.setDate(cur.getDate() + 7)
  }
  return out.sort()
}

function daysInMonth(year: number, month: number): number {
  return new Date(year, month + 1, 0).getDate()
}

export function allDatesInMonth(year: number, month: number): string[] {
  return Array.from({ length: daysInMonth(year, month) }, (_, i) => toDateStr(year, month, i + 1))
}

export function allDatesInYear(year: number): string[] {
  const out: string[] = []
  for (let m = 0; m < 12; m++) out.push(...allDatesInMonth(year, m))
  return out
}

/** Exclou dies amb festiu assignat (capa base) quan no es vol sobreescriure. */
export function excludeAssignedHolidayDates(
  dates: string[],
  assignedHolidays: Map<string, Holiday>,
  overwriteAssignedHolidays: boolean,
): string[] {
  if (overwriteAssignedHolidays) return dates
  return dates.filter((d) => !assignedHolidays.has(d))
}

interface PeriodStats {
  workDays: number
  totalMinutes: number
}

export function computePeriodStats(dayMap: Map<string, ResolvedDay>, dates: string[]): PeriodStats {
  let workDays = 0
  let totalMinutes = 0
  for (const d of dates) {
    const state = dayMap.get(d)
    if (state?.type === 'work') {
      workDays++
      totalMinutes += totalWorkMinutes(state.intervals)
    }
  }
  return { workDays, totalMinutes }
}

export function StatsSummary({
  stats, compact, t,
}: {
  stats: PeriodStats
  compact?: boolean
  t: ReturnType<typeof useTranslation>['t']
}) {
  const hoursLabel = formatWorkDuration(stats.totalMinutes)
  if (compact) {
    return (
      <span className="text-[10px] text-muted-foreground tabular-nums">
        {t('labor_cal.stats_month_summary', '{{days}} dies · {{hours}}', {
          days: stats.workDays,
          hours: hoursLabel,
        })}
      </span>
    )
  }
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground tabular-nums">
      <span>{t('labor_cal.stats_work_days', '{{count}} dies laborables', { count: stats.workDays })}</span>
      <span>{t('labor_cal.stats_work_hours', '{{hours}} de treball', { hours: hoursLabel })}</span>
    </div>
  )
}

function datesInMonthMatchingDow(year: number, month: number, jsDowArray: number[]): string[] {
  const out: string[] = []
  for (let d = 1; d <= daysInMonth(year, month); d++) {
    const date = toDateStr(year, month, d)
    const dow = new Date(`${date}T12:00:00`).getDay()
    if (jsDowArray.includes(dow)) out.push(date)
  }
  return out
}

function rotateMonFirstLabels<T>(weekStartsOn: number, labelsMonFirst: T[]): T[] {
  const order = weekColumnOrder(weekStartsOn)
  return order.map((jsDow) => {
    const idx = MON_FIRST_JS.indexOf(jsDow)
    return labelsMonFirst[idx]
  })
}

function checkboxIndexToJsDow(index: number, weekStartsOn: number): number {
  return weekColumnOrder(weekStartsOn)[index]
}

export interface ResolvedDay {
  date: string
  type: TenantDayType
  name?: string
  intervals: WorkInterval[]
  source:
    | 'employee_override'
    | 'group_site_override'
    | 'group_global_override'
    | 'group_override'
    | 'site_override'
    | 'tenant_override'
    | 'assigned_holiday'
    | 'none'
  tenantOverride?: LaborCalendarOverride
  siteOverride?: LaborCalendarOverride
  assignedHoliday?: Holiday
  fromAssignedHoliday?: boolean
  groupGlobalOverride?: LaborCalendarOverride
  groupSiteOverride?: LaborCalendarOverride
  groupOverride?: LaborCalendarOverride
  employeeOverride?: LaborCalendarOverride
  /** True when this day has a direct override at the group scope being edited. */
  hasScopeGroupOverride?: boolean
}

/**
 * Resolves the effective day type for every date in the year.
 * Weakest → strongest: Holiday → Tenant → Group(global) → Site → Group(site) → Employee
 */
export function buildDayMap(
  year: number,
  overrides: LaborCalendarOverride[],
  assignedHolidays: Map<string, Holiday>,
  contextSiteId: string | null | undefined,
  calendarGroupId?: string | null,
  employeeId?: string | null,
  groupOverrideSiteId?: string | null,
  /** calendar_groups.site_id — when set, the group is site-bound and group-global layer is skipped. */
  calendarGroupSiteId?: string | null,
): Map<string, ResolvedDay> {
  const tenantMap = new Map<string, LaborCalendarOverride>()
  const siteMap = new Map<string, LaborCalendarOverride>()
  const groupGlobalMap = new Map<string, LaborCalendarOverride>()
  const groupSiteMap = new Map<string, LaborCalendarOverride>()
  const employeeMap = new Map<string, LaborCalendarOverride>()

  for (const o of overrides) {
    const d = o.calendar_date
    if (o.employee_id && o.employee_id === employeeId) {
      employeeMap.set(d, o)
    } else if (o.group_id && o.group_id === calendarGroupId) {
      if (o.site_id) {
        if (!contextSiteId || o.site_id === contextSiteId) groupSiteMap.set(d, o)
      } else {
        groupGlobalMap.set(d, o)
      }
    } else if (o.site_id && o.site_id === contextSiteId) {
      siteMap.set(d, o)
    } else if (!o.site_id && !o.group_id && !o.employee_id) {
      tenantMap.set(d, o)
    }
  }

  const map = new Map<string, ResolvedDay>()
  const cur = new Date(`${year}-01-01T12:00:00`)
  const end = new Date(`${year}-12-31T12:00:00`)
  const scopeSite = groupOverrideSiteId ?? null
  const isSiteBoundGroup = !!calendarGroupSiteId

  while (cur <= end) {
    const date = cur.toISOString().slice(0, 10)

    const tenantOverride = tenantMap.get(date)
    const siteOverride = siteMap.get(date)
    const groupGlobalOverride = groupGlobalMap.get(date)
    const groupSiteOverride = groupSiteMap.get(date)
    const employeeOverride = employeeMap.get(date)
    const assignedHoliday = assignedHolidays.get(date)
    const groupOverride = groupSiteOverride ?? groupGlobalOverride

    const hasScopeGroupOverride = !!calendarGroupId && (
      scopeSite
        ? groupSiteOverride?.site_id === scopeSite
        : !!groupGlobalOverride && !groupGlobalOverride.site_id
    )

    const base: Omit<ResolvedDay, 'type' | 'name' | 'intervals' | 'source' | 'fromAssignedHoliday' | 'hasScopeGroupOverride'> = {
      date,
      tenantOverride,
      siteOverride,
      groupGlobalOverride,
      groupSiteOverride,
      groupOverride,
      employeeOverride,
      assignedHoliday,
    }

    if (employeeOverride) {
      const dayType = employeeOverride.day_type as TenantDayType
      map.set(date, {
        ...base,
        type: dayType,
        name: employeeOverride.day_name ?? undefined,
        intervals: intervalsFromOverride(employeeOverride),
        source: 'employee_override',
        fromAssignedHoliday: !!assignedHoliday && dayType === 'holiday',
        hasScopeGroupOverride,
      })
    } else if (groupSiteOverride) {
      const dayType = groupSiteOverride.day_type as TenantDayType
      map.set(date, {
        ...base,
        type: dayType,
        name: groupSiteOverride.day_name ?? undefined,
        intervals: intervalsFromOverride(groupSiteOverride),
        source: 'group_site_override',
        fromAssignedHoliday: !!assignedHoliday && dayType === 'holiday',
        hasScopeGroupOverride,
      })
    } else if (siteOverride) {
      const dayType = siteOverride.day_type as TenantDayType
      map.set(date, {
        ...base,
        type: dayType,
        name: siteOverride.day_name ?? undefined,
        intervals: intervalsFromOverride(siteOverride),
        source: 'site_override',
        fromAssignedHoliday: false,
        hasScopeGroupOverride,
      })
    } else if (!isSiteBoundGroup && groupGlobalOverride) {
      const dayType = groupGlobalOverride.day_type as TenantDayType
      map.set(date, {
        ...base,
        type: dayType,
        name: groupGlobalOverride.day_name ?? undefined,
        intervals: intervalsFromOverride(groupGlobalOverride),
        source: 'group_global_override',
        fromAssignedHoliday: !!assignedHoliday && dayType === 'holiday',
        hasScopeGroupOverride,
      })
    } else if (tenantOverride) {
      const dayType = tenantOverride.day_type as TenantDayType
      map.set(date, {
        ...base,
        type: dayType,
        name: tenantOverride.day_name ?? undefined,
        intervals: intervalsFromOverride(tenantOverride),
        source: 'tenant_override',
        fromAssignedHoliday: false,
        hasScopeGroupOverride,
      })
    } else if (assignedHoliday) {
      map.set(date, {
        ...base,
        type: 'holiday',
        name: assignedHoliday.name ?? undefined,
        intervals: [],
        source: 'assigned_holiday',
        fromAssignedHoliday: true,
        hasScopeGroupOverride,
      })
    } else {
      map.set(date, {
        ...base,
        type: 'undefined',
        intervals: [],
        source: 'none',
        hasScopeGroupOverride,
      })
    }

    cur.setDate(cur.getDate() + 1)
  }
  return map
}

function dayCellClasses(
  type: TenantDayType,
  selected: boolean,
  faded?: boolean,
): string {
  const s = DAY_STYLE[type]
  return [
    s.cell,
    s.hover,
    selected ? `ring-2 ${s.ring} ring-offset-0 z-10 font-bold` : '',
    faded ? 'opacity-45' : '',
  ].filter(Boolean).join(' ')
}

export interface DaySelectionAnalysis {
  canPrefill: boolean
  mixedTypes: boolean
  mixedSchedules: boolean
  mixedNames: boolean
  type: TenantDayType | null
  name: string
  intervals: WorkInterval[]
}

/** Whether selected days share one editable value set (single day always when type ≠ undefined). */
export function analyzeDaySelection(states: ResolvedDay[]): DaySelectionAnalysis {
  const base: DaySelectionAnalysis = {
    canPrefill: false,
    mixedTypes: false,
    mixedSchedules: false,
    mixedNames: false,
    type: null,
    name: '',
    intervals: defaultIntervals(),
  }
  if (states.length === 0) return base

  if (states.length === 1) {
    const s = states[0]
    if (s.type === 'undefined') return base
    return {
      canPrefill: true,
      mixedTypes: false,
      mixedSchedules: false,
      mixedNames: false,
      type: s.type,
      name: s.name ?? '',
      intervals: s.type === 'work' && s.intervals.length > 0 ? s.intervals : defaultIntervals(),
    }
  }

  const types = states.map((s) => s.type)
  const firstType = types[0]
  if (types.some((t) => t !== firstType)) {
    return { ...base, mixedTypes: true }
  }
  if (firstType === 'undefined') {
    return { ...base, mixedTypes: true }
  }

  if (firstType === 'work') {
    const keys = states.map((s) => intervalsKey(s.intervals))
    if (keys.some((k) => k !== keys[0])) {
      return { ...base, mixedSchedules: true }
    }
    const iv = states[0].intervals.length > 0 ? states[0].intervals : defaultIntervals()
    return {
      canPrefill: true,
      mixedTypes: false,
      mixedSchedules: false,
      mixedNames: false,
      type: 'work',
      name: '',
      intervals: iv,
    }
  }

  const names = states.map((s) => s.name ?? '')
  if (names.some((n) => n !== names[0])) {
    return { ...base, mixedNames: true, type: firstType }
  }
  return {
    canPrefill: true,
    mixedTypes: false,
    mixedSchedules: false,
    mixedNames: false,
    type: firstType,
    name: names[0],
    intervals: defaultIntervals(),
  }
}

interface GridProps {
  year: number
  month: number
  weekStartsOn: number
  dowAbbr: string[]
  dowFull: string[]
  dayMap: Map<string, ResolvedDay>
  selected: Set<string>
  dragAnchor: string | null
  compact?: boolean
  dateFormat: string
  onDayMouseDown: (d: string, e: MouseEvent) => void
  onDayMouseEnter: (d: string) => void
  onDayClick?: (d: string, e: MouseEvent) => void
  overnightSuffix: string
  t: ReturnType<typeof useTranslation>['t']
  scheduleFilters?: ScheduleFilterState
  groupOverridesOnly?: boolean
  /** Extra classes per day cell (e.g. absence ring overlay). */
  dayOverlayClass?: (date: string) => string | undefined
}

export function MonthMiniGrid({
  year, month, weekStartsOn, dowAbbr, dayMap, selected, dragAnchor, compact,
  dateFormat, onDayMouseDown, onDayMouseEnter, onDayClick, overnightSuffix, t,
  scheduleFilters,
  groupOverridesOnly,
  dayOverlayClass,
}: GridProps) {
  const offset = firstDayColumnOffset(year, month, weekStartsOn)
  const cells: (string | null)[] = []
  for (let i = 0; i < offset; i++) cells.push(null)
  for (let d = 1; d <= daysInMonth(year, month); d++) cells.push(toDateStr(year, month, d))

  return (
    <div className="grid grid-cols-7 gap-[2px]">
      {dowAbbr.map((d) => (
        <div key={d} className={`text-center font-semibold text-muted-foreground ${compact ? 'text-[9px]' : 'text-[11px]'}`}>
          {d}
        </div>
      ))}
      {cells.map((date, i) => {
        if (!date) return <div key={`e${i}`} />
        const state: ResolvedDay = dayMap.get(date) ?? { date, type: 'undefined', intervals: [], source: 'none' }
        const isSel = selected.has(date) || dragAnchor === date
        const faded = groupOverridesOnly && !state.hasScopeGroupOverride
        const overlay = dayOverlayClass?.(date) ?? ''
        return (
          <CalendarDayTooltip
            key={date}
            state={state}
            dateFormat={dateFormat}
            overnightSuffix={overnightSuffix}
            t={t}
          >
            <div
              className={`relative flex items-center justify-center rounded cursor-pointer transition-colors touch-manipulation ${compact ? 'h-5 text-[10px]' : 'h-7 text-[11px]'} ${dayCellClasses(state.type, isSel, faded)} ${state.hasScopeGroupOverride ? 'ring-1 ring-primary/70' : ''} ${scheduleFilters ? dayScheduleMarkers(state, scheduleFilters) : ''} ${overlay}`}
              onMouseDown={(e) => { if (e.button === 0) { e.preventDefault(); onDayMouseDown(date, e) } }}
              onMouseEnter={() => onDayMouseEnter(date)}
              onClick={(e) => onDayClick?.(date, e)}
            >
              {Number(date.slice(8))}
            </div>
          </CalendarDayTooltip>
        )
      })}
    </div>
  )
}

export function MonthFullGrid({
  year, month, weekStartsOn, dowAbbr, dayMap, selected, dragAnchor,
  dateFormat, onDayMouseDown, onDayMouseEnter, onDayClick, overnightSuffix, t,
  scheduleFilters,
  groupOverridesOnly,
  dayOverlayClass,
}: Omit<GridProps, 'compact' | 'dowFull'>) {
  const offset = firstDayColumnOffset(year, month, weekStartsOn)
  const cells: (string | null)[] = []
  for (let i = 0; i < offset; i++) cells.push(null)
  for (let d = 1; d <= daysInMonth(year, month); d++) cells.push(toDateStr(year, month, d))

  return (
    <div className="grid grid-cols-7 gap-1">
      {dowAbbr.map((d) => (
        <div key={d} className="text-center text-[11px] font-semibold text-muted-foreground py-1.5 border-b uppercase">{d}</div>
      ))}
      {cells.map((date, i) => {
        if (!date) return <div key={`e${i}`} className="min-h-[5.5rem] sm:min-h-24" />
        const state: ResolvedDay = dayMap.get(date) ?? { date, type: 'undefined', intervals: [], source: 'none' }
        const isSel = selected.has(date) || dragAnchor === date
        const faded = groupOverridesOnly && !state.hasScopeGroupOverride
        const overlay = dayOverlayClass?.(date) ?? ''
        return (
          <CalendarDayTooltip
            key={date}
            state={state}
            dateFormat={dateFormat}
            overnightSuffix={overnightSuffix}
            t={t}
          >
            <div
              className={`relative rounded-lg p-1.5 min-h-[5.5rem] sm:min-h-24 cursor-pointer flex flex-col gap-0.5 touch-manipulation ${dayCellClasses(state.type, isSel, faded)} ${state.hasScopeGroupOverride ? 'ring-1 ring-primary/70' : ''} ${scheduleFilters ? dayScheduleMarkers(state, scheduleFilters) : ''} ${overlay}`}
              onMouseDown={(e) => { if (e.button === 0) { e.preventDefault(); onDayMouseDown(date, e) } }}
              onMouseEnter={() => onDayMouseEnter(date)}
              onClick={(e) => onDayClick?.(date, e)}
            >
              <span className="text-xs font-semibold shrink-0">{Number(date.slice(8))}</span>
              {state.name && <span className="text-[10px] truncate opacity-90 shrink-0">{state.name}</span>}
              {state.type === 'work' && state.intervals.length > 0 && (
                <div className="mt-auto min-w-0 space-y-0.5 text-[10px] leading-tight opacity-90">
                  {state.intervals.slice(0, 2).map((iv, idx) => (
                    <div key={idx} className="truncate tabular-nums">{formatInterval(iv, overnightSuffix)}</div>
                  ))}
                  {state.intervals.length > 2 && (
                    <div className="truncate text-muted-foreground">+{state.intervals.length - 2}</div>
                  )}
                </div>
              )}
            </div>
          </CalendarDayTooltip>
        )
      })}
    </div>
  )
}

interface ApplyParams {
  dayType: TenantDayType
  dayName?: string
  workIntervals?: WorkInterval[]
}

export function DayInspector({
  state,
  dateFormat,
  overnightSuffix,
  hideCascade = false,
  hideSelectedTitle = false,
  t,
}: {
  state: ResolvedDay
  dateFormat: string
  overnightSuffix: string
  hideCascade?: boolean
  hideSelectedTitle?: boolean
  t: ReturnType<typeof useTranslation>['t']
}) {
  const [showCascade, setShowCascade] = useState(false)

  function toCascadeState(override: LaborCalendarOverride | undefined): ResolvedDay | undefined {
    if (!override || override.day_type === 'leave') return undefined
    return {
      ...state,
      type: override.day_type as TenantDayType,
      name: override.day_name ?? undefined,
      intervals: intervalsFromOverride(override),
    }
  }

  function candidateLabel(s: ResolvedDay | undefined): string {
    if (!s) return t('labor_cal.cascade_none', 'No aplicat')
    const type = t(`labor_cal.type_${s.type}`, DAY_STYLE[s.type].label)
    return s.name ? `${type} · ${s.name}` : type
  }

  const workMinutes = state.type === 'work' ? totalWorkMinutes(state.intervals) : 0

  const cascadeItems: { key: ResolvedDay['source']; label: string; state: ResolvedDay | undefined }[] = [
    {
      key: 'assigned_holiday',
      label: t('labor_cal.cascade_assigned_holiday', 'Festiu assignat'),
      state: state.assignedHoliday
        ? ({ ...state, type: 'holiday' as const, name: state.assignedHoliday.name ?? undefined, intervals: [] } as ResolvedDay)
        : undefined,
    },
    {
      key: 'tenant_override',
      label: t('labor_cal.cascade_tenant_override', 'Override empresa'),
      state: toCascadeState(state.tenantOverride),
    },
    ...(state.groupGlobalOverride !== undefined || state.source === 'group_global_override' ? [{
      key: 'group_global_override' as const,
      label: t('labor_cal.cascade_group_global_override', 'Override grup (patró comú)'),
      state: toCascadeState(state.groupGlobalOverride),
    }] : []),
    {
      key: 'site_override',
      label: t('labor_cal.cascade_site_override', 'Override local'),
      state: toCascadeState(state.siteOverride),
    },
    ...(state.groupSiteOverride !== undefined || state.source === 'group_site_override' ? [{
      key: 'group_site_override' as const,
      label: t('labor_cal.cascade_group_site_override', 'Override grup (ajust per local)'),
      state: toCascadeState(state.groupSiteOverride),
    }] : []),
    ...(state.employeeOverride !== undefined || state.source === 'employee_override' ? [{
      key: 'employee_override' as const,
      label: t('labor_cal.cascade_employee_override', 'Override empleat'),
      state: toCascadeState(state.employeeOverride),
    }] : []),
  ]

  return (
    <div className="rounded-lg border bg-muted/30 p-3 text-xs space-y-3">
      {!hideSelectedTitle && (
        <p className="font-semibold text-sm">
          {t('labor_cal.selected_day_title', 'Dia seleccionat')}: {formatIsoDateWithPattern(state.date, dateFormat)}
        </p>
      )}
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-muted-foreground">{t('labor_cal.effective_from', 'Valor efectiu')}:</span>
        <span className={`inline-flex items-center rounded-full px-2.5 py-1 text-xs font-semibold ${DAY_STYLE[state.type].badge}`}>
          {candidateLabel(state)}
        </span>
      </div>
      {state.type === 'work' && (
        <div className="rounded-md border bg-background/80 px-3 py-2 space-y-1">
          <p className="font-medium text-muted-foreground">{t('labor_cal.work_intervals', 'Horari')}</p>
          {state.intervals.length > 0 ? (
            <>
              <ul className="text-sm tabular-nums space-y-0.5 list-none">
                {state.intervals.map((iv, idx) => (
                  <li key={idx}>{formatInterval(iv, overnightSuffix)}</li>
                ))}
              </ul>
              <p className="text-muted-foreground">
                {t('labor_cal.work_hours_total', 'Hores de treball')}:{' '}
                <span className="font-semibold text-foreground">{formatWorkDuration(workMinutes)}</span>
              </p>
            </>
          ) : (
            <p className="text-muted-foreground italic">{t('labor_cal.cascade_none', 'No aplicat')}</p>
          )}
        </div>
      )}
      {!hideCascade && (
      <button
        type="button"
        onClick={() => setShowCascade((v) => !v)}
        className="flex items-center gap-1.5 text-muted-foreground hover:text-foreground transition-colors"
      >
        {showCascade ? <ChevronUp className="h-3.5 w-3.5" /> : <ChevronDown className="h-3.5 w-3.5" />}
        {showCascade
          ? t('labor_cal.cascade_toggle_hide', 'Amagar cascada de valors')
          : t('labor_cal.cascade_toggle_show', 'Veure cascada de valors')}
      </button>
      )}
      {!hideCascade && showCascade && (
        <div className="grid gap-2">
          {cascadeItems.map((item) => {
            const applies = state.source === item.key
            const itemMinutes = item.state?.type === 'work' ? totalWorkMinutes(item.state.intervals) : 0
            return (
              <div
                key={item.key}
                className={`rounded-md border px-2.5 py-2 space-y-1 ${applies ? 'border-primary/40 bg-primary/5' : 'border-border bg-background/70'}`}
              >
                <div className="flex flex-wrap items-center gap-2">
                  <span className="min-w-[9rem] font-medium text-muted-foreground">{item.label}</span>
                  <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs ${item.state ? DAY_STYLE[item.state.type].badge : 'bg-muted text-muted-foreground border'}`}>
                    {item.state ? candidateLabel(item.state) : t('labor_cal.cascade_none', 'No aplicat')}
                  </span>
                  <span className={`ml-auto text-[11px] ${applies ? 'text-primary font-semibold' : 'text-muted-foreground'}`}>
                    {applies ? t('labor_cal.cascade_applied', 'Aplica') : t('labor_cal.cascade_not_applied', 'No aplica')}
                  </span>
                </div>
                {item.state?.type === 'work' && item.state.intervals.length > 0 && (
                  <p className="text-[11px] text-muted-foreground pl-0 tabular-nums">
                    {formatIntervalsList(item.state.intervals, overnightSuffix)}
                    {' · '}
                    {formatWorkDuration(itemMinutes)}
                  </p>
                )}
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}

export function CalendarEditSidebar({
  count,
  selectedDates,
  selectedStates,
  inspectedState,
  dateFormat,
  overnightSuffix,
  onApply,
  onClear,
  onRevert,
  canRevert,
  isPending,
  groupEditMode,
  footerExtra,
  t,
}: {
  count: number
  selectedDates: string[]
  selectedStates: ResolvedDay[]
  inspectedState: ResolvedDay | null | undefined
  dateFormat: string
  overnightSuffix: string
  onApply: (p: ApplyParams) => void
  onClear: () => void
  onRevert?: () => void
  canRevert?: boolean
  isPending: boolean
  groupEditMode?: boolean
  footerExtra?: ReactNode
  t: ReturnType<typeof useTranslation>['t']
}) {
  const dayTypes = groupEditMode
    ? TENANT_DAY_TYPES.filter((type) => type !== 'undefined')
    : TENANT_DAY_TYPES

  const selectionKey = selectedStates.map((s) => s.date).sort().join('|')
  const analysis = useMemo(() => analyzeDaySelection(selectedStates), [selectionKey])

  const [activeType, setActiveType] = useState<TenantDayType | null>(null)
  const [dayName, setDayName] = useState('')
  const [intervals, setIntervals] = useState<WorkInterval[]>(defaultIntervals())

  useEffect(() => {
    const a = analyzeDaySelection(selectedStates)
    if (a.canPrefill && a.type) {
      setActiveType(a.type)
      setDayName(a.name)
      setIntervals(a.type === 'work' ? a.intervals : defaultIntervals())
    } else {
      setActiveType(null)
      setDayName('')
      setIntervals(defaultIntervals())
    }
  }, [selectionKey])

  const intervalError = activeType === 'work' ? validateWorkIntervals(intervals) : null
  const canApply = !!activeType && !intervalError

  const mixedHint = analysis.mixedTypes
    ? t('labor_cal.selection_mixed_types', 'Els dies seleccionats tenen tipus de jornada diferents. Trieu el valor a aplicar.')
    : analysis.mixedSchedules
      ? t('labor_cal.selection_mixed_schedules', 'Els dies seleccionats tenen horaris diferents. Trieu el nou horari.')
      : analysis.mixedNames
        ? t('labor_cal.selection_mixed_names', 'Els dies seleccionats tenen noms o notes diferents. Introduïu el valor a aplicar.')
        : null

  function handleApply() {
    if (!activeType || intervalError) return
    onApply({
      dayType: activeType,
      dayName: (activeType === 'holiday' || activeType === 'vacation') && dayName.trim() ? dayName.trim() : undefined,
      workIntervals: activeType === 'work' ? intervals : undefined,
    })
  }

  return (
    <aside className="w-full sm:w-80 shrink-0 border-l bg-muted/15 flex flex-col max-h-[calc(100vh-6rem)] sticky top-16 self-start">
      <div className="px-4 py-3 border-b bg-background/80 shrink-0">
        <h3 className="text-sm font-semibold">{t('labor_cal.edit_panel_title', 'Edició del calendari')}</h3>
        <p className="text-[11px] text-muted-foreground mt-1">
          {t('labor_cal.edit_panel_hint', 'Clic o arrossega per seleccionar. Ctrl+clic per afegir o treure dies no consecutius.')}
        </p>
      </div>

      <div className="flex-1 min-h-0 overflow-y-auto p-4 space-y-4">
        {count === 0 ? (
          <p className="text-xs text-muted-foreground">
            {t('labor_cal.edit_panel_empty', 'Selecciona un o més dies al calendari per editar-los aquí.')}
          </p>
        ) : (
          <>
            <p className="text-sm font-medium text-muted-foreground">
              {count === 1
                ? formatIsoDateWithPattern(selectedDates[0], dateFormat)
                : t('labor_cal.selected_many', '{{count}} dies', { count })}
            </p>

            {count === 1 && inspectedState && (
              <DayInspector
                state={inspectedState}
                dateFormat={dateFormat}
                overnightSuffix={overnightSuffix}
                t={t}
              />
            )}
            {count > 1 && (
              <p className="text-xs text-muted-foreground rounded-md border bg-muted/30 px-3 py-2">
                {t('labor_cal.cascade_multi_hint', 'Per veure la cascada de valors, selecciona un únic dia.')}
              </p>
            )}

            {mixedHint && (
              <p className="text-xs text-amber-800 dark:text-amber-200 rounded-md border border-amber-200 bg-amber-50 dark:bg-amber-950/30 px-3 py-2">
                {mixedHint}
              </p>
            )}

            <div className="space-y-3">
              <p className="text-xs font-medium text-muted-foreground">{t('labor_cal.day_type', 'Tipus')}</p>
              <div className="flex flex-wrap gap-1.5">
                {dayTypes.map((type) => {
                  const s = DAY_STYLE[type]
                  const active = activeType === type
                  return (
                    <button
                      key={type}
                      type="button"
                      onClick={() => setActiveType(active ? null : type)}
                      className={`px-2.5 py-1 rounded-full text-xs font-medium transition-all ${s.badge} ${active ? `ring-2 ${s.ring}` : 'opacity-80 hover:opacity-100'}`}
                    >
                      {t(`labor_cal.type_${type}`, s.label)}
                    </button>
                  )
                })}
              </div>
              {activeType === 'work' && (
                <WorkIntervalsEditor intervals={intervals} onChange={setIntervals} />
              )}
              {(activeType === 'holiday' || activeType === 'vacation') && (
                <input
                  className="border rounded-md px-2 py-1.5 text-xs bg-background w-full"
                  placeholder={activeType === 'holiday' ? t('labor_cal.holiday_name', 'Nom del festiu') : t('labor_cal.vacation_note', 'Nota (opcional)')}
                  value={dayName}
                  onChange={(e) => setDayName(e.target.value)}
                />
              )}
            </div>
          </>
        )}
      </div>

      {count > 0 && (
        <div className="shrink-0 border-t bg-background p-4 space-y-2">
          {footerExtra}
          {groupEditMode && canRevert && onRevert && (
            <Button size="sm" variant="outline" disabled={isPending} onClick={onRevert} className="w-full h-8 text-xs">
              {t('labor_cal.revert_group_override', 'Desfer canvis')}
            </Button>
          )}
          <div className="flex gap-2">
            <Button size="sm" variant="outline" disabled={isPending} onClick={onClear} className="flex-1 h-9">
              {t('labor_cal.cancel', 'Cancel·lar')}
            </Button>
            <Button size="sm" disabled={isPending || !canApply} onClick={handleApply} className="flex-1 h-9 gap-1">
              <Check className="h-3.5 w-3.5" />
              {t('labor_cal.apply', 'Aplicar')}
            </Button>
          </div>
        </div>
      )}
    </aside>
  )
}

type CalendarView = 'year' | 'month'

function WeeklyPatternPanel({
  year, month, view, weekStartsOn, monthLabel, dowFullMonFirst, onClose,
  calendarGroupId, groupEditMode, groupOverrideSiteId, assignedHolidays,
}: {
  year: number
  month: number
  view: CalendarView
  weekStartsOn: number
  monthLabel: string
  dowFullMonFirst: string[]
  onClose: () => void
  calendarGroupId?: string | null
  groupEditMode?: boolean
  groupOverrideSiteId?: string | null
  assignedHolidays: Map<string, Holiday>
}) {
  const { t } = useTranslation('attendance')
  const { mutate: applyYearPattern, isPending: applyingYear } = useApplyWeeklyPattern()
  const { mutate: upsertDays, isPending: upserting } = useUpsertLaborCalendarDays()
  const { selectedSiteId } = useTenant()
  const [checkedDows, setCheckedDows] = useState([true, true, true, true, true, false, false])
  const [overwriteAssignedHolidays, setOverwriteAssignedHolidays] = useState(false)
  const [dayType, setDayType] = useState<TenantDayType>('work')
  const [intervals, setIntervals] = useState<WorkInterval[]>(defaultIntervals())
  const [dayName, setDayName] = useState('')
  const isPending = applyingYear || upserting
  const intervalError = dayType === 'work' ? validateWorkIntervals(intervals) : null
  const isMonthScope = view === 'month'
  const dayTypes = groupEditMode
    ? TENANT_DAY_TYPES.filter((type) => type !== 'undefined')
    : TENANT_DAY_TYPES

  const presetLabelKeys: Record<string, string> = {
    '08-16': 'labor_cal.quick_preset_08_16',
    '08-14-15-17': 'labor_cal.quick_preset_08_14_15_17',
    '09-13-1630-2030': 'labor_cal.quick_preset_09_13_1630_2030',
  }

  function scopePayload() {
    if (calendarGroupId) {
      return {
        siteId: groupOverrideSiteId ?? null,
        groupId: calendarGroupId,
      }
    }
    return { siteId: undefined as string | null | undefined, groupId: null as string | null }
  }

  function filterPatternDates(dates: string[]): string[] {
    return excludeAssignedHolidayDates(dates, assignedHolidays, overwriteAssignedHolidays)
  }

  function applyPatternForDows(jsDoW: number[], payload: {
    dayType: TenantDayType
    dayName?: string | null
    workIntervals?: WorkInterval[] | null
  }, onDone?: () => void) {
    const base = { ...payload, ...scopePayload() }
    const skipAssignedHolidays = !overwriteAssignedHolidays
    if (isMonthScope) {
      const dates = filterPatternDates(datesInMonthMatchingDow(year, month, jsDoW))
      if (!dates.length) {
        onDone?.()
        return
      }
      upsertDays({ dates, ...base }, { onSuccess: onDone })
    } else {
      applyYearPattern({ year, dowArray: jsDoW, skipAssignedHolidays, ...base }, { onSuccess: onDone })
    }
  }

  function applyQuickWeekdayWeekend(presetIntervals: WorkInterval[]) {
    applyPatternForDows([...WEEKDAY_JS_DOW], {
      dayType: 'work',
      dayName: null,
      workIntervals: presetIntervals,
    }, () => {
      applyPatternForDows([...WEEKEND_JS_DOW], {
        dayType: 'holiday',
        dayName: null,
        workIntervals: null,
      }, onClose)
    })
  }

  function applyAllUndefined() {
    if (isMonthScope) {
      upsertDays({
        dates: allDatesInMonth(year, month),
        dayType: 'undefined',
        dayName: null,
        workIntervals: null,
        siteId: selectedSiteId,
      }, { onSuccess: onClose })
    } else {
      applyYearPattern({
        year,
        dowArray: [0, 1, 2, 3, 4, 5, 6],
        dayType: 'undefined',
        dayName: null,
        workIntervals: null,
        siteId: selectedSiteId,
      }, { onSuccess: onClose })
    }
  }

  function handleApply() {
    const jsDoW = checkedDows
      .map((c, idx) => (c ? checkboxIndexToJsDow(idx, weekStartsOn) : -1))
      .filter((d) => d >= 0)
    if (!jsDoW.length || intervalError) return

    const payload = {
      dayType,
      dayName: dayName.trim() || null,
      workIntervals: dayType === 'work' ? intervals : null,
      ...scopePayload(),
    }

    if (isMonthScope) {
      const dates = filterPatternDates(datesInMonthMatchingDow(year, month, jsDoW))
      if (!dates.length) {
        onClose()
        return
      }
      upsertDays({
        dates,
        ...payload,
      }, { onSuccess: onClose })
    } else {
      applyYearPattern({
        year,
        dowArray: jsDoW,
        skipAssignedHolidays: !overwriteAssignedHolidays,
        ...payload,
      }, { onSuccess: onClose })
    }
  }

  return (
    <div className="rounded-xl border bg-muted/30 p-4 space-y-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold flex items-center gap-2">
          <Settings2 className="h-4 w-4" />
          {isMonthScope
            ? t('labor_cal.weekly_panel_title_month', 'Patró setmanal pel mes de {{month}}', { month: monthLabel })
            : t('labor_cal.weekly_panel_title', 'Patró setmanal per a {{year}}', { year })}
        </h3>
        <button type="button" onClick={onClose}><X className="h-4 w-4" /></button>
      </div>

      {!groupEditMode && (
      <div className="space-y-2 rounded-lg border bg-background/60 p-3">
        <p className="text-xs font-semibold text-muted-foreground">
          {t('labor_cal.quick_preset_title', 'Assignació ràpida')}
        </p>
        <p className="text-[11px] text-muted-foreground">
          {t('labor_cal.quick_preset_weekday_weekend', 'Entre setmana laboral · cap de setmana festiu')}
        </p>
        <div className="flex flex-wrap gap-1.5">
          {QUICK_WEEKDAY_PRESETS.map((preset) => (
            <Button
              key={preset.id}
              variant="outline"
              size="sm"
              disabled={isPending}
              className="h-7 text-[11px]"
              onClick={() => applyQuickWeekdayWeekend(preset.intervals)}
            >
              {t(presetLabelKeys[preset.id] ?? preset.id, preset.id)}
            </Button>
          ))}
          <Button
            variant="outline"
            size="sm"
            disabled={isPending}
            className="h-7 text-[11px]"
            onClick={applyAllUndefined}
          >
            {t('labor_cal.quick_preset_all_undefined', 'Tot indefinit')}
          </Button>
        </div>
      </div>
      )}

      {groupEditMode && (
        <p className="text-[11px] text-muted-foreground rounded-md border border-dashed px-3 py-2">
          {t('labor_cal.group_weekly_hint', "Només s'apliquen overrides del grup. Els valors heretats de l'empresa o el local no es modifiquen.")}
        </p>
      )}

      <label className="flex items-start gap-2 cursor-pointer select-none text-xs rounded-md border bg-background/60 px-3 py-2">
        <input
          type="checkbox"
          checked={overwriteAssignedHolidays}
          onChange={(e) => setOverwriteAssignedHolidays(e.target.checked)}
          className="rounded mt-0.5"
        />
        <span>
          <span className="font-medium">{t('labor_cal.overwrite_assigned_holidays', 'Sobreescriure festius assignats')}</span>
          <span className="block text-[11px] text-muted-foreground mt-0.5">
            {t('labor_cal.overwrite_assigned_holidays_hint', 'Per defecte, els dies amb festiu oficial al calendari importat no es modifiquen.')}
          </span>
        </span>
      </label>

      <div className="flex flex-wrap gap-x-4 gap-y-2">
        {dowFullMonFirst.map((label, idx) => (
          <label key={label} className="flex items-center gap-2 cursor-pointer select-none text-sm">
            <input
              type="checkbox"
              checked={checkedDows[idx]}
              onChange={(e) => {
                const next = [...checkedDows]
                next[idx] = e.target.checked
                setCheckedDows(next)
              }}
              className="rounded"
            />
            {label}
          </label>
        ))}
      </div>
      <div className="flex flex-wrap gap-1.5">
        {dayTypes.map((type) => {
          const s = DAY_STYLE[type]
          return (
            <button
              key={type}
              type="button"
              onClick={() => setDayType(type)}
              className={`px-2.5 py-0.5 rounded-full text-xs font-medium ${s.badge} ${dayType === type ? `ring-2 ${s.ring}` : 'opacity-70'}`}
            >
              {t(`labor_cal.type_${type}`, s.label)}
            </button>
          )
        })}
      </div>
      {dayType === 'work' && <WorkIntervalsEditor intervals={intervals} onChange={setIntervals} />}
      {(dayType === 'holiday' || dayType === 'vacation') && (
        <input
          className="w-full max-w-md border rounded-md px-3 py-1.5 text-xs bg-background"
          placeholder={t('labor_cal.optional_name', 'Nom / nota (opcional)')}
          value={dayName}
          onChange={(e) => setDayName(e.target.value)}
        />
      )}
      <div className="flex justify-end gap-2">
        <Button variant="outline" size="sm" onClick={onClose} className="h-7 text-xs">{t('labor_cal.cancel', 'Cancel·lar')}</Button>
        <Button size="sm" disabled={isPending || !checkedDows.some(Boolean) || !!intervalError} onClick={handleApply} className="h-7 text-xs">
          {isPending
            ? t('labor_cal.applying', 'Aplicant…')
            : isMonthScope
              ? t('labor_cal.apply_pattern_month', 'Aplicar al mes')
              : t('labor_cal.apply_pattern', "Aplicar a tot l'any")}
        </Button>
      </div>
    </div>
  )
}

interface LaborCalendarGridProps {
  /** When set, overrides the global site selector and saves overrides under this group. */
  calendarGroupId?: string | null
  /** The group's own site_id from calendar_groups (null = global group). */
  calendarGroupSiteId?: string | null
  /** Label shown in the context banner when calendarGroupId is set. */
  calendarGroupName?: string | null
  /** Color for the group context banner. */
  calendarGroupColor?: string | null
  /** Explicit site scope for group override rows (decoupled from sidebar). */
  groupEditScopeSiteId?: string | null
  /** Site used to resolve the local layer when previewing a group calendar. */
  groupPreviewSiteId?: string | null
}

export function LaborCalendarGrid({
  calendarGroupId,
  calendarGroupSiteId,
  calendarGroupName,
  calendarGroupColor,
  groupEditScopeSiteId,
  groupPreviewSiteId,
}: LaborCalendarGridProps = {}) {
  const { t } = useTranslation('attendance')
  const { selectedSiteId, activeSite, activeTenant, sites } = useTenant()
  const { dateFormat, weekStartsOn } = useCalendarDisplaySettings()
  const overnightSuffix = t('labor_cal.overnight_suffix', ' (+1)')

  const monthNames = t('labor_cal.months', { returnObjects: true }) as string[]
  const dowAbbrMonFirst = t('labor_cal.dow_abbr', { returnObjects: true }) as string[]
  const dowFullMonFirst = t('labor_cal.dow_full', { returnObjects: true }) as string[]
  const dowAbbrHeaders = useMemo(() => rotateMonFirstLabels(weekStartsOn, dowAbbrMonFirst), [weekStartsOn, dowAbbrMonFirst])
  const dowFullHeaders = useMemo(() => rotateMonFirstLabels(weekStartsOn, dowFullMonFirst), [weekStartsOn, dowFullMonFirst])

  const currentYear = new Date().getFullYear()
  const [year, setYear] = useState(currentYear)
  const [view, setView] = useState<CalendarView>('year')
  const [month, setMonth] = useState(new Date().getMonth())
  const [showWeeklyPanel, setShowWeeklyPanel] = useState(false)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [dragAnchor, setDragAnchor] = useState<string | null>(null)
  const isDragging = useRef(false)
  const didDrag = useRef(false)

  const isGroupContext = !!calendarGroupId
  const isSiteBoundGroup = !!calendarGroupSiteId
  const groupOverrideSiteId = isGroupContext
    ? (isSiteBoundGroup ? calendarGroupSiteId! : (groupEditScopeSiteId ?? null))
    : null
  const [groupViewMode, setGroupViewMode] = useState<'resolved' | 'overrides_only'>('resolved')
  const cascadeSiteId = isGroupContext
    ? (groupPreviewSiteId ?? groupOverrideSiteId ?? selectedSiteId)
    : selectedSiteId

  useEffect(() => {
    const up = () => { isDragging.current = false }
    document.addEventListener('mouseup', up)
    return () => document.removeEventListener('mouseup', up)
  }, [])

  const handleMouseDown = useCallback((date: string, e: MouseEvent) => {
    if (e.button !== 0) return
    const coarse = typeof window !== 'undefined' && window.matchMedia('(pointer: coarse)').matches
    if (coarse) return
    if (e.ctrlKey || e.metaKey) {
      e.preventDefault()
      isDragging.current = false
      didDrag.current = false
      setDragAnchor(null)
      setSelected((prev) => {
        const next = new Set(prev)
        if (next.has(date)) next.delete(date)
        else next.add(date)
        return next
      })
      return
    }
    isDragging.current = true
    didDrag.current = false
    setDragAnchor(date)
    setSelected(new Set([date]))
  }, [])

  const handleMouseEnter = useCallback((date: string) => {
    if (!isDragging.current || !dragAnchor || date === dragAnchor) return
    didDrag.current = true
    setSelected(new Set(rectDateRange(dragAnchor, date, weekStartsOn)))
  }, [dragAnchor, weekStartsOn])

  const handleDayClick = useCallback((date: string, e: MouseEvent) => {
    if (e.ctrlKey || e.metaKey) return
    if (didDrag.current) {
      didDrag.current = false
      return
    }
    const coarse = typeof window !== 'undefined' && window.matchMedia('(pointer: coarse)').matches
    if (!coarse) return
    e.preventDefault()
    setSelected(new Set([date]))
    setDragAnchor(null)
    isDragging.current = false
  }, [])

  const { data: overrides = [], isLoading } = useLaborCalendarOverrides(year)
  const { data: assignedHolidays = new Map() } = useAssignedHolidays(year)
  const { mutate: upsert, isPending: upserting } = useUpsertLaborCalendarDays()

  const dayMap = useMemo(
    () => buildDayMap(
      year,
      overrides,
      assignedHolidays,
      cascadeSiteId,
      calendarGroupId,
      undefined,
      groupOverrideSiteId,
      calendarGroupSiteId,
    ),
    [year, overrides, assignedHolidays, cascadeSiteId, calendarGroupId, groupOverrideSiteId, calendarGroupSiteId],
  )

  const sf = useScheduleFilters(dayMap)

  const selectedDates = useMemo(() => [...selected].sort(), [selected])
  const selectedStates = useMemo(
    () => selectedDates
      .map((d) => dayMap.get(d))
      .filter((s): s is ResolvedDay => !!s),
    [selectedDates, dayMap],
  )
  const monthLabel = monthNames[month] ?? String(month + 1)
  const inspectedDate = selectedDates.length === 1 ? selectedDates[0] : null
  const inspectedState = inspectedDate ? dayMap.get(inspectedDate) : null

  const yearStats = useMemo(
    () => computePeriodStats(dayMap, allDatesInYear(year)),
    [dayMap, year],
  )
  const monthStats = useMemo(
    () => computePeriodStats(dayMap, allDatesInMonth(year, month)),
    [dayMap, year, month],
  )
  const viewStats = view === 'year' ? yearStats : monthStats

  function handleApply(params: ApplyParams) {
    upsert({
      dates: selectedDates,
      dayType: params.dayType,
      dayName: params.dayName ?? null,
      workIntervals: params.workIntervals ?? null,
      siteId: isGroupContext ? (groupOverrideSiteId ?? null) : undefined,
      groupId: calendarGroupId ?? null,
    }, { onSuccess: () => setSelected(new Set()) })
  }

  function handleRevertGroupOverrides() {
    if (!isGroupContext || !calendarGroupId) return
    upsert({
      dates: selectedDates,
      dayType: 'undefined',
      siteId: groupOverrideSiteId ?? null,
      groupId: calendarGroupId,
    }, { onSuccess: () => setSelected(new Set()) })
  }

  const canRevertGroupOverrides = isGroupContext && selectedDates.some((date) => {
    const day = dayMap.get(date)
    return day?.hasScopeGroupOverride
  })
  const isSiteContext = !isGroupContext && !!selectedSiteId
  const contextName = isGroupContext
    ? (calendarGroupName ?? calendarGroupId)
    : isSiteContext
      ? (activeSite?.name ?? selectedSiteId)
      : (activeTenant?.name ?? '')

  const gridCommon = {
    dayMap, selected, dragAnchor, weekStartsOn, dateFormat,
    onDayMouseDown: handleMouseDown, onDayMouseEnter: handleMouseEnter, onDayClick: handleDayClick,
    overnightSuffix, t,
    scheduleFilters: sf.filterState(isGroupContext),
    groupOverridesOnly: isGroupContext && groupViewMode === 'overrides_only',
  }

  const previewSiteName = cascadeSiteId
    ? (sites.find((s) => s.id === cascadeSiteId)?.name ?? cascadeSiteId)
    : null

  return (
    <div className="select-none flex flex-col lg:flex-row gap-0 items-start">
      <div className="flex-1 min-w-0 space-y-4 lg:pr-4">
      <div
        className={`flex flex-wrap items-start justify-between gap-3 rounded-lg border px-4 py-3 text-sm ${
          isGroupContext
            ? ''
            : isSiteContext
              ? 'bg-blue-50 border-blue-300 text-blue-900 dark:bg-blue-950/40 dark:border-blue-700 dark:text-blue-100'
              : 'bg-amber-50 border-amber-300 text-amber-900 dark:bg-amber-950/40 dark:border-amber-700 dark:text-amber-100'
        }`}
        style={isGroupContext && calendarGroupColor
          ? { borderColor: calendarGroupColor + '88', backgroundColor: calendarGroupColor + '18' }
          : undefined}
      >
        {isGroupContext
          ? <div className="h-4 w-4 shrink-0 rounded-full" style={{ backgroundColor: calendarGroupColor ?? '#6366f1' }} />
          : isSiteContext
            ? <MapPin className="h-4 w-4 shrink-0" />
            : <Building2 className="h-4 w-4 shrink-0" />}
        <div className="flex-1 min-w-0">
          <p className="font-semibold">
            {isGroupContext
              ? isSiteBoundGroup
                ? t('labor_cal.context_group_site_title', 'Grup «{{name}}» ({{site}})', {
                    name: contextName,
                    site: previewSiteName ?? '—',
                  })
                : groupOverrideSiteId
                  ? t('labor_cal.context_group_local_adj_title', 'Grup «{{name}}» — excepció a {{site}}', {
                      name: contextName,
                      site: previewSiteName ?? '—',
                    })
                  : t('labor_cal.context_group_global_title', 'Grup «{{name}}» — patró comú', { name: contextName })
              : isSiteContext
                ? t('labor_cal.context_site', 'Calendari del local: {{name}}', { name: contextName })
                : t('labor_cal.context_tenant', "Calendari de l'empresa: {{name}}", { name: contextName })}
          </p>
          <p className="text-xs opacity-80 mt-0.5">
            {isGroupContext
              ? isSiteBoundGroup
                ? t('labor_cal.context_group_site_bound_desc', 'Aquest grup només aplica a aquest local. Preval sobre el calendari del centre per als empleats assignats.')
                : groupOverrideSiteId
                  ? t('labor_cal.context_group_local_adj_desc', 'Excepció del mateix grup només en aquest centre. Preval sobre el patró comú i el calendari del centre.')
                  : t('labor_cal.context_group_global_desc', 'Patró compartit per tots els locals. Els centres i els ajustos per local el poden modificar.')
              : isSiteContext
                ? t('labor_cal.context_site_desc', "Calendari d'aquest centre. Hereta el de l'empresa on no hi hagi override.")
                : t('labor_cal.context_tenant_desc', "Calendari per defecte de tota l'empresa.")}
          </p>
        </div>
        {isGroupContext && (
          <div className="flex rounded-md border p-0.5 shrink-0">
            {(['resolved', 'overrides_only'] as const).map((mode) => (
              <button
                key={mode}
                type="button"
                className={`rounded px-2.5 py-1 text-[11px] font-medium whitespace-nowrap ${groupViewMode === mode ? 'bg-primary text-primary-foreground' : 'hover:bg-accent'}`}
                onClick={() => setGroupViewMode(mode)}
              >
                {mode === 'resolved'
                  ? t('labor_cal.group_view_resolved', 'Vista resolta')
                  : t('labor_cal.group_view_overrides', 'Només overrides')}
              </button>
            ))}
          </div>
        )}
      </div>

      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Button variant="outline" size="sm" onClick={() => (view === 'year' ? setYear((y) => y - 1) : month === 0 ? (setYear((y) => y - 1), setMonth(11)) : setMonth((m) => m - 1))} className="h-8 w-8 p-0"><ChevronLeft className="h-4 w-4" /></Button>
          <span className="min-w-[9rem] text-center text-sm font-semibold">
            {view === 'year' ? year : `${monthLabel} ${year}`}
          </span>
          <Button variant="outline" size="sm" onClick={() => (view === 'year' ? setYear((y) => y + 1) : month === 11 ? (setYear((y) => y + 1), setMonth(0)) : setMonth((m) => m + 1))} className="h-8 w-8 p-0"><ChevronRight className="h-4 w-4" /></Button>
          <Button variant="outline" size="sm" className="h-8 text-xs" onClick={() => { setYear(currentYear); setMonth(new Date().getMonth()) }}>
            {t('labor_cal.today', 'Avui')}
          </Button>
          <StatsSummary stats={viewStats} t={t} />
        </div>
        <div className="flex items-center gap-2">
          <Button variant="outline" size="sm" className="h-8 gap-1 text-xs" onClick={() => setShowWeeklyPanel((v) => !v)}>
            <Settings2 className="h-3.5 w-3.5" />
            {t('labor_cal.weekly_setup', 'Patró setmanal')}
          </Button>
          <div className="flex rounded-md border p-0.5">
            {(['year', 'month'] as CalendarView[]).map((v) => (
              <button key={v} type="button" className={`rounded px-3 py-1 text-xs font-medium ${view === v ? 'bg-primary text-primary-foreground' : 'hover:bg-accent'}`} onClick={() => setView(v)}>
                {v === 'year' ? t('labor_cal.view_year', 'Any') : t('labor_cal.view_month', 'Mes')}
              </button>
            ))}
          </div>
        </div>
      </div>

      {showWeeklyPanel && (
        <WeeklyPatternPanel
          year={year}
          month={month}
          view={view}
          weekStartsOn={weekStartsOn}
          monthLabel={monthLabel}
          dowFullMonFirst={dowFullHeaders}
          onClose={() => setShowWeeklyPanel(false)}
          calendarGroupId={calendarGroupId}
          groupEditMode={isGroupContext}
          groupOverrideSiteId={groupOverrideSiteId}
          assignedHolidays={assignedHolidays}
        />
      )}

      <ScheduleFilterBar
        scheduleIndex={sf.scheduleIndex}
        hourBuckets={sf.hourBuckets}
        intervalFilterKey={sf.intervalFilterKey}
        hourFilter={sf.hourFilter}
        overnightSuffix={overnightSuffix}
        onClear={sf.clearFilters}
        onToggleInterval={sf.toggleIntervalFilter}
        onToggleHour={sf.toggleHourFilter}
      />

      <div className="flex flex-wrap items-center gap-x-5 gap-y-2 text-xs text-muted-foreground">
        {TENANT_DAY_TYPES.map((type) => {
          const s = DAY_STYLE[type]
          return (
            <div key={type} className="flex items-center gap-2">
              <span className={`inline-block h-3.5 w-3.5 rounded-sm shrink-0 ${s.legendMark}`} aria-hidden />
              <span>{t(`labor_cal.type_${type}`, s.label)}</span>
            </div>
          )
        })}
        {isLoading && <span>{t('labor_cal.loading', 'Carregant…')}</span>}
      </div>

      {view === 'year' ? (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
          {Array.from({ length: 12 }, (_, m) => {
            const mStats = computePeriodStats(dayMap, allDatesInMonth(year, m))
            return (
            <div key={m} className="rounded-lg border bg-card p-3">
              <div className="mb-1 flex items-center justify-between gap-1">
                <div className="min-w-0">
                  <span className="text-xs font-semibold">{monthNames[m] ?? m + 1}</span>
                  <div className="mt-0.5">
                    <StatsSummary stats={mStats} compact t={t} />
                  </div>
                </div>
                <button type="button" className="text-muted-foreground hover:text-primary shrink-0" onClick={() => { setMonth(m); setView('month') }} title={t('labor_cal.view_month_btn', 'Veure mes')}>
                  <CalendarDays className="h-3.5 w-3.5" />
                </button>
              </div>
              <MonthMiniGrid year={year} month={m} compact dowAbbr={dowAbbrHeaders} dowFull={dowFullHeaders} {...gridCommon} />
            </div>
            )
          })}
        </div>
      ) : (
        <div className="rounded-lg border bg-card p-4">
          <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
            <h3 className="text-sm font-semibold">{monthLabel} {year}</h3>
            <StatsSummary stats={monthStats} t={t} />
          </div>
          <MonthFullGrid year={year} month={month} dowAbbr={dowAbbrHeaders} {...gridCommon} />
        </div>
      )}

      </div>

      <CalendarEditSidebar
        count={selected.size}
        selectedDates={selectedDates}
        selectedStates={selectedStates}
        inspectedState={inspectedState}
        dateFormat={dateFormat}
        overnightSuffix={overnightSuffix}
        onApply={handleApply}
        onClear={() => { setSelected(new Set()); setDragAnchor(null) }}
        onRevert={handleRevertGroupOverrides}
        canRevert={canRevertGroupOverrides}
        isPending={upserting}
        groupEditMode={isGroupContext}
        t={t}
      />
    </div>
  )
}
