import { useCallback, useMemo, useState } from 'react'

export type DashboardWidgetId =
  | 'stats'
  | 'employees'
  | 'map'
  | 'calendar'
  | 'incidents'
  | 'pending_absences'
  | 'legal_risk'
  | 'coverage_gaps'
  | 'station_fleet'

export type EmployeeViewMode = 'table' | 'cards'
export type CalendarScope = 'site' | 'tenant'
export type DashboardCalendarView = 'week' | 'month'

export interface CalendarMonthPanels {
  prev: boolean
  current: boolean
  next: boolean
}

export interface DashboardLayoutState {
  employeeView: EmployeeViewMode
  calendarScope: CalendarScope
  calendarView: DashboardCalendarView
  calendarAnchorIso: string
  calendarMonthPanels: CalendarMonthPanels
  widgets: Record<DashboardWidgetId, boolean>
}

const STORAGE_KEY = 'attendance-dashboard-layout-v4'

const DEFAULT_MONTH_PANELS: CalendarMonthPanels = {
  prev: false,
  current: true,
  next: false,
}

const DEFAULT_WIDGETS: Record<DashboardWidgetId, boolean> = {
  stats: true,
  employees: true,
  map: true,
  calendar: true,
  incidents: true,
  pending_absences: true,
  legal_risk: true,
  coverage_gaps: true,
  station_fleet: true,
}

function todayIso(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

const DEFAULT_STATE: DashboardLayoutState = {
  employeeView: 'cards',
  calendarScope: 'site',
  calendarView: 'month',
  calendarAnchorIso: todayIso(),
  calendarMonthPanels: DEFAULT_MONTH_PANELS,
  widgets: DEFAULT_WIDGETS,
}

type LegacyWidgetState = Partial<Record<string, boolean>>

function migrateWidgets(legacy?: LegacyWidgetState): Record<DashboardWidgetId, boolean> {
  const widgets = { ...DEFAULT_WIDGETS }
  if (!legacy) return widgets

  if (legacy.stats != null) widgets.stats = legacy.stats
  if (legacy.employees != null) widgets.employees = legacy.employees
  if (legacy.map != null) widgets.map = legacy.map
  if (legacy.incidents != null) widgets.incidents = legacy.incidents
  if (legacy.pending_absences != null) widgets.pending_absences = legacy.pending_absences
  if (legacy.legal_risk != null) widgets.legal_risk = legacy.legal_risk
  if (legacy.coverage_gaps != null) widgets.coverage_gaps = legacy.coverage_gaps
  if (legacy.station_fleet != null) widgets.station_fleet = legacy.station_fleet
  if (legacy.calendar != null) {
    widgets.calendar = legacy.calendar
  } else if (
    legacy.calendar_prev
    || legacy.calendar_current
    || legacy.calendar_next
    || legacy.calendar_week
  ) {
    widgets.calendar = true
  }

  return widgets
}

function migrateMonthPanels(parsed: Partial<DashboardLayoutState>): CalendarMonthPanels {
  if (parsed.calendarMonthPanels) {
    return {
      prev: Boolean(parsed.calendarMonthPanels.prev),
      current: parsed.calendarMonthPanels.current !== false,
      next: Boolean(parsed.calendarMonthPanels.next),
    }
  }
  const offset = (parsed as { calendarMonthOffset?: number }).calendarMonthOffset
  if (offset === -1) return { prev: true, current: false, next: false }
  if (offset === 1) return { prev: false, current: false, next: true }
  return { ...DEFAULT_MONTH_PANELS }
}

function loadState(): DashboardLayoutState {
  try {
    for (const key of [STORAGE_KEY, 'attendance-dashboard-layout-v3', 'attendance-dashboard-layout-v2', 'attendance-dashboard-layout-v1']) {
      const raw = localStorage.getItem(key)
      if (!raw) continue
      const parsed = JSON.parse(raw) as Partial<DashboardLayoutState>
      return {
        employeeView: parsed.employeeView === 'table' ? 'table' : 'cards',
        calendarScope: parsed.calendarScope === 'tenant' ? 'tenant' : 'site',
        calendarView: parsed.calendarView === 'week' ? 'week' : 'month',
        calendarAnchorIso: parsed.calendarAnchorIso?.slice(0, 10) ?? todayIso(),
        calendarMonthPanels: migrateMonthPanels(parsed),
        widgets: migrateWidgets(parsed.widgets),
      }
    }
    return DEFAULT_STATE
  } catch {
    return DEFAULT_STATE
  }
}

export function useDashboardLayout() {
  const [state, setState] = useState<DashboardLayoutState>(loadState)

  const persist = useCallback((next: DashboardLayoutState) => {
    setState(next)
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next))
  }, [])

  const setEmployeeView = useCallback(
    (employeeView: EmployeeViewMode) => persist({ ...state, employeeView }),
    [persist, state],
  )

  const setCalendarScope = useCallback(
    (calendarScope: CalendarScope) => persist({ ...state, calendarScope }),
    [persist, state],
  )

  const setCalendarView = useCallback(
    (calendarView: DashboardCalendarView) => persist({ ...state, calendarView }),
    [persist, state],
  )

  const setCalendarAnchorIso = useCallback(
    (calendarAnchorIso: string) => persist({ ...state, calendarAnchorIso: calendarAnchorIso.slice(0, 10) }),
    [persist, state],
  )

  const setCalendarMonthPanels = useCallback(
    (calendarMonthPanels: CalendarMonthPanels) => persist({ ...state, calendarMonthPanels }),
    [persist, state],
  )

  const shiftCalendarPeriod = useCallback(
    (delta: number) => {
      const anchor = new Date(`${state.calendarAnchorIso}T12:00:00`)
      if (state.calendarView === 'week') {
        anchor.setDate(anchor.getDate() + delta * 7)
      } else {
        anchor.setMonth(anchor.getMonth() + delta)
        anchor.setDate(1)
      }
      const iso = `${anchor.getFullYear()}-${String(anchor.getMonth() + 1).padStart(2, '0')}-${String(anchor.getDate()).padStart(2, '0')}`
      persist({ ...state, calendarAnchorIso: iso })
    },
    [persist, state],
  )

  const goCalendarToday = useCallback(() => {
    persist({ ...state, calendarAnchorIso: todayIso() })
  }, [persist, state])

  const toggleWidget = useCallback(
    (id: DashboardWidgetId) => {
      persist({
        ...state,
        widgets: { ...state.widgets, [id]: !state.widgets[id] },
      })
    },
    [persist, state],
  )

  const resetLayout = useCallback(() => persist({ ...DEFAULT_STATE, calendarAnchorIso: todayIso() }), [persist])

  const visibleWidgets = useMemo(
    () => (Object.keys(state.widgets) as DashboardWidgetId[]).filter((id) => state.widgets[id]),
    [state.widgets],
  )

  return {
    state,
    visibleWidgets,
    setEmployeeView,
    setCalendarScope,
    setCalendarView,
    setCalendarAnchorIso,
    setCalendarMonthPanels,
    shiftCalendarPeriod,
    goCalendarToday,
    toggleWidget,
    resetLayout,
  }
}

export const WIDGET_LABELS: Record<DashboardWidgetId, string> = {
  stats: 'dashboard.widget_stats',
  employees: 'dashboard.widget_employees',
  map: 'dashboard.widget_map',
  calendar: 'dashboard.widget_calendar',
  incidents: 'dashboard.widget_incidents',
  pending_absences: 'dashboard.widget_pending_absences',
  legal_risk: 'dashboard.widget_legal_risk',
  coverage_gaps: 'dashboard.widget_coverage_gaps',
  station_fleet: 'dashboard.widget_station_fleet',
}
