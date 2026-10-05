import {
  getMonthGridDays,
  startOfDay,
  startOfWeekMonday,
} from '../../calendar/calendarDateUtils'
import { localDateString, localDaysHalfOpenRange } from '../../../lib/dateLocal'
import type { AgendaView } from './agendaUrlState'

/** Half-open local ranges for `list_field_visits` (`>= from AND < to`). */
export function rangeForView(view: AgendaView, anchor: Date): { from: string; to: string } {
  if (view === 'list') {
    return localDaysHalfOpenRange(14, localDateString(anchor))
  }
  if (view === 'day') {
    return localDaysHalfOpenRange(1, localDateString(anchor))
  }
  if (view === 'week') {
    const weekStart = startOfWeekMonday(anchor)
    return localDaysHalfOpenRange(7, localDateString(weekStart))
  }
  // Exact same day set as CalendarGrid month cells.
  const monthDays = getMonthGridDays(anchor)
  const first =
    monthDays[0] ?? startOfWeekMonday(new Date(anchor.getFullYear(), anchor.getMonth(), 1))
  return localDaysHalfOpenRange(monthDays.length || 42, localDateString(first))
}

export function startOfMonthAnchor(anchor: Date): Date {
  return startOfDay(new Date(anchor.getFullYear(), anchor.getMonth(), 1))
}
