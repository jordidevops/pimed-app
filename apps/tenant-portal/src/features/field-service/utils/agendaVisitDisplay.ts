import { addDays, dateKey, startOfDay } from '../../calendar/calendarDateUtils'
import { daysSpannedByEvent } from '../../calendar/projectEventsOntoDays'
import type { FieldVisit } from '../api/fieldVisitsService'

export type VisitDayPlacement = {
  visit: FieldVisit
  dayKey: string
  continuesFrom: boolean
  continuesTo: boolean
}

/** Group visits onto each overlapping day in [windowStart, windowEnd] (inclusive). */
export function placeVisitsOnDays(
  visits: FieldVisit[],
  windowStart: Date,
  windowEnd: Date,
): Map<string, VisitDayPlacement[]> {
  const start = startOfDay(windowStart)
  const end = startOfDay(windowEnd)
  const byId = new Map(visits.map((v) => [v.id, v]))
  const map = new Map<string, VisitDayPlacement[]>()

  for (const visit of visits) {
    if (!visit.planned_start) continue
    const keys = daysSpannedByEvent(
      {
        id: visit.id,
        start: visit.planned_start,
        end: visit.planned_end,
        allDay: isMidnightLocalSafe(visit.planned_start),
      },
      start,
      end,
    )
    const spanStart = dateKey(visit.planned_start)
    const spanKeys = daysSpannedByEvent(
      {
        id: visit.id,
        start: visit.planned_start,
        end: visit.planned_end,
        allDay: isMidnightLocalSafe(visit.planned_start),
      },
      new Date(2000, 0, 1),
      new Date(2100, 0, 1),
    )
    const spanEnd = spanKeys[spanKeys.length - 1] ?? spanStart

    for (const key of keys) {
      const list = map.get(key) ?? []
      list.push({
        visit: byId.get(visit.id) ?? visit,
        dayKey: key,
        continuesFrom: key > spanStart,
        continuesTo: key < spanEnd,
      })
      map.set(key, list)
    }
  }

  for (const [, list] of map) {
    list.sort((a, b) =>
      (a.visit.planned_start ?? '').localeCompare(b.visit.planned_start ?? ''),
    )
  }
  return map
}

function isMidnightLocalSafe(iso: string): boolean {
  const d = new Date(iso)
  return d.getHours() === 0 && d.getMinutes() === 0 && d.getSeconds() === 0
}

export function formatClock(
  iso: string | null | undefined,
  locale: string,
): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  if (d.getHours() === 0 && d.getMinutes() === 0) return ''
  return d.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' })
}

export function formatDayShort(isoOrKey: string, locale: string): string {
  const d = isoOrKey.includes('T')
    ? new Date(isoOrKey)
    : (() => {
        const [y, m, day] = isoOrKey.split('-').map(Number)
        return new Date(y, m - 1, day)
      })()
  return d.toLocaleDateString(locale, { day: 'numeric', month: 'short' })
}

/**
 * Start/end labels for a visit as seen on a specific calendar day.
 * Cross-day ends show the end date; continuations hide the far-side clock.
 */
export function visitTimeLabelsForDay(
  visit: FieldVisit,
  day: Date,
  locale: string,
): {
  allDay: boolean
  startLabel: string
  endLabel: string
  continuesFrom: boolean
  continuesTo: boolean
} {
  const dayStart = startOfDay(day)
  const dayEnd = addDays(dayStart, 1)
  const start = visit.planned_start ? new Date(visit.planned_start) : null
  const end = visit.planned_end ? new Date(visit.planned_end) : null
  const startClock = formatClock(visit.planned_start, locale)
  const endClock = formatClock(visit.planned_end, locale)
  const allDay = Boolean(start && !startClock)

  const continuesFrom = Boolean(start && start < dayStart)
  const continuesTo = Boolean(end && end >= dayEnd)

  let startLabel = ''
  let endLabel = ''

  if (allDay) {
    return { allDay: true, startLabel: '', endLabel: '', continuesFrom, continuesTo }
  }

  if (continuesFrom) {
    startLabel = '…'
  } else {
    startLabel = startClock
  }

  if (!end) {
    endLabel = ''
  } else if (continuesTo) {
    endLabel = endClock
      ? `→ ${formatDayShort(visit.planned_end!, locale)} ${endClock}`
      : `→ ${formatDayShort(visit.planned_end!, locale)}`
  } else if (continuesFrom || (start && dateKey(start) !== dateKey(end))) {
    endLabel = endClock || formatDayShort(visit.planned_end!, locale)
  } else {
    endLabel = endClock
  }

  return { allDay: false, startLabel, endLabel, continuesFrom, continuesTo }
}
