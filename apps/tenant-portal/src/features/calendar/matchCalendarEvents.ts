export type MatchableCalendarEvent = {
  id: string
  title?: string | null
  description?: string | null
  entity_type?: string | null
  resolvedLabel?: string | null
  start_at?: string | null
}

const MIN_QUERY_LENGTH = 1

export function normalizeSearchQuery(raw: string | null | undefined): string {
  return (raw ?? '').trim().toLowerCase()
}

export function isSearchQueryActive(raw: string | null | undefined): boolean {
  return normalizeSearchQuery(raw).length >= MIN_QUERY_LENGTH
}

/**
 * Case-insensitive match on title (primary), then description / label / entity_type.
 * Empty query returns all events (caller should gate UI instead).
 */
export function matchCalendarEvents<T extends MatchableCalendarEvent>(
  events: T[],
  query: string | null | undefined,
): T[] {
  const q = normalizeSearchQuery(query)
  if (!q) return events

  return events.filter((event) => {
    const haystacks = [
      event.title,
      event.description,
      event.resolvedLabel,
      event.entity_type,
    ]
    return haystacks.some((field) => {
      if (!field) return false
      return field.toLowerCase().includes(q)
    })
  })
}

/** Prefer event start day for navigation; fallback to today key if missing. */
export function eventSearchAnchorDate(event: MatchableCalendarEvent): string | null {
  if (!event.start_at) return null
  const d = new Date(event.start_at)
  if (Number.isNaN(d.getTime())) return null
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}
