import { addDays, dateKey, startOfDay } from './calendarDateUtils'
import type { CalendarResolvedEvent } from './calendar.types'

export type ProjectableEvent = {
  id: string
  start: string | Date
  end?: string | Date | null
  allDay?: boolean | null
}

/** Resolved calendar rows ready for day projection (guaranteed id + start_at). */
export type ProjectableResolvedEvent = CalendarResolvedEvent &
  ProjectableEvent & {
    id: string
    start_at: string
  }

export function toProjectableResolvedEvents(
  events: CalendarResolvedEvent[],
): ProjectableResolvedEvent[] {
  return events
    .filter(
      (e): e is CalendarResolvedEvent & { id: string; start_at: string } =>
        typeof e.id === 'string' &&
        e.id.length > 0 &&
        typeof e.start_at === 'string' &&
        e.start_at.length > 0,
    )
    .map((e) => ({
      ...e,
      start: e.start_at,
      end: e.end_at ?? null,
      allDay: e.all_day ?? null,
    }))
}

/**
 * Inclusive local calendar days an event occupies within [rangeStart, rangeEnd].
 * All-day / midnight end_at uses exclusive-end semantics (end day not included).
 */
export function daysSpannedByEvent(
  event: ProjectableEvent,
  rangeStart: Date,
  rangeEnd: Date,
): string[] {
  if (!event.start) return []

  const start = startOfDay(new Date(event.start))
  const endRaw = event.end != null ? new Date(event.end) : null
  const allDay = Boolean(event.allDay)

  let lastInclusive: Date
  if (!endRaw || Number.isNaN(endRaw.getTime())) {
    lastInclusive = start
  } else if (isExclusiveEndInstant(endRaw, allDay)) {
    const dayBefore = addDays(startOfDay(endRaw), -1)
    lastInclusive = dayBefore < start ? start : dayBefore
  } else {
    lastInclusive = startOfDay(endRaw)
    if (lastInclusive < start) lastInclusive = start
  }

  const windowStart = startOfDay(rangeStart)
  const windowEnd = startOfDay(rangeEnd)
  let cursor = start < windowStart ? windowStart : start
  const stop = lastInclusive > windowEnd ? windowEnd : lastInclusive

  const keys: string[] = []
  while (cursor <= stop) {
    keys.push(dateKey(cursor))
    cursor = addDays(cursor, 1)
  }
  return keys
}

/** Midnight local end (or all-day end) marks the first day NOT included. */
function isExclusiveEndInstant(end: Date, allDay: boolean): boolean {
  if (allDay) {
    return end.getHours() === 0 && end.getMinutes() === 0 && end.getSeconds() === 0
  }
  return end.getHours() === 0 && end.getMinutes() === 0 && end.getSeconds() === 0
}

/**
 * Group events onto each overlapping local day (multiday-aware).
 * Same event id may appear under multiple day keys.
 */
export function projectEventsOntoDays<T extends ProjectableEvent>(
  events: T[],
  rangeStart: Date,
  rangeEnd: Date,
): Map<string, T[]> {
  const grouped = new Map<string, T[]>()
  for (const event of events) {
    const days = daysSpannedByEvent(event, rangeStart, rangeEnd)
    for (const key of days) {
      const list = grouped.get(key) ?? []
      list.push(event)
      grouped.set(key, list)
    }
  }
  for (const [, list] of grouped) {
    list.sort((a, b) => new Date(a.start).getTime() - new Date(b.start).getTime())
  }
  return grouped
}

const HEX_COLOR = /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/

export function resolveEventColor(raw: string | null | undefined, fallback = '#6366f1'): string {
  if (!raw) return fallback
  const trimmed = raw.trim()
  if (HEX_COLOR.test(trimmed)) return trimmed
  return fallback
}
