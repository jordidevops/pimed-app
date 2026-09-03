export type DatePreset = 'all' | '7d' | '30d' | '90d' | 'custom'

export interface TimelineFilterState {
  includeAudit: boolean
  includeBackground: boolean
  tasksOnly: boolean
  openTasksOnly: boolean
  datePreset: DatePreset
  /** Valor d'<input type="date"> (YYYY-MM-DD) */
  dateFrom: string
  dateTo: string
  /** Text de cerca (es debounceja al component pare) */
  search: string
}

export const DEFAULT_TIMELINE_FILTERS: TimelineFilterState = {
  includeAudit: true,
  includeBackground: false,
  tasksOnly: false,
  openTasksOnly: false,
  datePreset: 'all',
  dateFrom: '',
  dateTo: '',
  search: '',
}

function dateInputToIsoStart(dateStr: string): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  return new Date(y, m - 1, d, 0, 0, 0, 0).toISOString()
}

function dateInputToIsoEnd(dateStr: string): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  return new Date(y, m - 1, d, 23, 59, 59, 999).toISOString()
}

function daysAgoIso(n: number): string {
  const d = new Date()
  d.setDate(d.getDate() - n)
  d.setHours(0, 0, 0, 0)
  return d.toISOString()
}

export function resolveTimelineDateRange(
  state: Pick<TimelineFilterState, 'datePreset' | 'dateFrom' | 'dateTo'>,
): { dateFrom?: string; dateTo?: string } {
  if (state.datePreset === 'all') return {}

  if (state.datePreset === 'custom') {
    return {
      ...(state.dateFrom ? { dateFrom: dateInputToIsoStart(state.dateFrom) } : {}),
      ...(state.dateTo ? { dateTo: dateInputToIsoEnd(state.dateTo) } : {}),
    }
  }

  const days = state.datePreset === '7d' ? 7 : state.datePreset === '30d' ? 30 : 90
  return { dateFrom: daysAgoIso(days) }
}

export function hasActiveTimelineFilters(state: TimelineFilterState): boolean {
  return (
    !state.includeAudit ||
    state.includeBackground ||
    state.tasksOnly ||
    state.openTasksOnly ||
    (state.datePreset !== 'all' &&
      (state.datePreset !== 'custom' || !!state.dateFrom || !!state.dateTo)) ||
    !!state.search.trim()
  )
}
