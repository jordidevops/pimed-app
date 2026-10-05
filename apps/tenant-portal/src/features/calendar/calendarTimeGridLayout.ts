import { addDays, isMidnightLocal, startOfDay } from './calendarDateUtils'

export const SLOT_MINUTES = 30
export const DAY_MINUTES = 24 * 60
export const SLOTS_PER_DAY = DAY_MINUTES / SLOT_MINUTES
/** Pixel height of one 30-minute slot. */
export const SLOT_HEIGHT_PX = 28
/** Scroll so ~07:00 is near the top on first paint. */
export const DEFAULT_SCROLL_HOUR = 7

export type TimeGridEventLike = {
  id: string
  start: string | Date
  end?: string | Date | null
  allDay?: boolean | null
}

export type TimedLayoutRect = {
  id: string
  /** Minutes from local midnight (clipped to day). */
  startMin: number
  endMin: number
  column: number
  columnCount: number
}

export function minutesFromMidnight(date: Date): number {
  return date.getHours() * 60 + date.getMinutes() + date.getSeconds() / 60
}

export function dateAtMinutes(day: Date, minutes: number): Date {
  const base = startOfDay(day)
  const whole = Math.floor(minutes)
  return new Date(
    base.getFullYear(),
    base.getMonth(),
    base.getDate(),
    Math.floor(whole / 60),
    whole % 60,
    0,
    0,
  )
}

export function isAllDayEvent(event: TimeGridEventLike, treatMidnightAsAllDay = true): boolean {
  if (Boolean(event.allDay)) return true
  if (!treatMidnightAsAllDay) return false
  const start = new Date(event.start)
  if (!isMidnightLocal(start)) return false
  if (event.end == null) return true
  const end = new Date(event.end)
  return isMidnightLocal(end)
}

/**
 * Clip a timed event to a local calendar day as [startMin, endMin) in minutes.
 * Returns null if the event does not overlap the day as a timed block.
 */
export function clipTimedEventToDay(
  event: TimeGridEventLike,
  day: Date,
): { startMin: number; endMin: number } | null {
  if (isAllDayEvent(event)) return null

  const dayStart = startOfDay(day)
  const dayEnd = addDays(dayStart, 1)
  const start = new Date(event.start)
  if (Number.isNaN(start.getTime())) return null

  let end =
    event.end != null
      ? new Date(event.end)
      : new Date(start.getTime() + SLOT_MINUTES * 60_000)
  if (Number.isNaN(end.getTime()) || end <= start) {
    end = new Date(start.getTime() + SLOT_MINUTES * 60_000)
  }

  if (end <= dayStart || start >= dayEnd) return null

  const clippedStart = start < dayStart ? dayStart : start
  const clippedEnd = end > dayEnd ? dayEnd : end
  let startMin = minutesFromMidnight(clippedStart)
  let endMin = clippedEnd.getTime() === dayEnd.getTime() ? DAY_MINUTES : minutesFromMidnight(clippedEnd)

  if (endMin <= startMin) endMin = Math.min(DAY_MINUTES, startMin + SLOT_MINUTES)
  startMin = Math.max(0, Math.min(startMin, DAY_MINUTES - 1))
  endMin = Math.max(startMin + 1, Math.min(endMin, DAY_MINUTES))
  return { startMin, endMin }
}

/**
 * Greedy column packing for overlapping timed events on one day.
 * Sorted by start, then longer first.
 */
export function layoutTimedEventsForDay(
  events: TimeGridEventLike[],
  day: Date,
): TimedLayoutRect[] {
  const clipped = events
    .map((event) => {
      const span = clipTimedEventToDay(event, day)
      if (!span) return null
      return { id: event.id, ...span }
    })
    .filter((x): x is { id: string; startMin: number; endMin: number } => x != null)
    .sort((a, b) => a.startMin - b.startMin || b.endMin - a.endMin - (a.endMin - a.startMin))

  type Active = { endMin: number; column: number }
  const active: Active[] = []
  const assigned: Array<{ id: string; startMin: number; endMin: number; column: number }> = []

  for (const ev of clipped) {
    for (let i = active.length - 1; i >= 0; i--) {
      if (active[i]!.endMin <= ev.startMin) active.splice(i, 1)
    }
    const used = new Set(active.map((a) => a.column))
    let column = 0
    while (used.has(column)) column += 1
    active.push({ endMin: ev.endMin, column })
    assigned.push({ ...ev, column })
  }

  // Cluster overlapping groups to set columnCount per cluster.
  const rects: TimedLayoutRect[] = assigned.map((a) => ({
    ...a,
    columnCount: 1,
  }))

  for (let i = 0; i < assigned.length; i++) {
    const cluster = new Set<number>([i])
    let changed = true
    while (changed) {
      changed = false
      for (let j = 0; j < assigned.length; j++) {
        if (cluster.has(j)) continue
        const b = assigned[j]!
        for (const idx of cluster) {
          const a = assigned[idx]!
          if (a.startMin < b.endMin && b.startMin < a.endMin) {
            cluster.add(j)
            changed = true
            break
          }
        }
      }
    }
    let maxCol = 0
    for (const idx of cluster) {
      maxCol = Math.max(maxCol, assigned[idx]!.column)
    }
    const columnCount = maxCol + 1
    for (const idx of cluster) {
      rects[idx]!.columnCount = Math.max(rects[idx]!.columnCount, columnCount)
    }
  }

  return rects
}

export function slotLabel(slotIndex: number, locale: string): string {
  const minutes = slotIndex * SLOT_MINUTES
  if (minutes % 60 !== 0) return ''
  const d = dateAtMinutes(new Date(2000, 0, 1), minutes)
  return d.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit' })
}
