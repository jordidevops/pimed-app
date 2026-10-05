import { describe, expect, it } from 'vitest'
import {
  eventSearchAnchorDate,
  isSearchQueryActive,
  matchCalendarEvents,
  normalizeSearchQuery,
} from './matchCalendarEvents'

const events = [
  {
    id: '1',
    title: 'Reunió comercial',
    description: 'Client Acme',
    entity_type: 'manual',
    resolvedLabel: 'Event',
    start_at: '2026-10-08T10:00:00',
  },
  {
    id: '2',
    title: 'Manteniment caldera',
    description: null,
    entity_type: 'project',
    resolvedLabel: 'Projecte',
    start_at: '2026-10-09T08:00:00',
  },
  {
    id: '3',
    title: null,
    description: 'Sense títol però amb Acme al cos',
    entity_type: 'task',
    resolvedLabel: 'Tasca',
    start_at: '2026-10-10T12:00:00',
  },
]

describe('matchCalendarEvents', () => {
  it('normalizes and detects active queries', () => {
    expect(normalizeSearchQuery('  Foo  ')).toBe('foo')
    expect(isSearchQueryActive('  ')).toBe(false)
    expect(isSearchQueryActive('a')).toBe(true)
  })

  it('matches title case-insensitively', () => {
    const hits = matchCalendarEvents(events, 'reuniÓ')
    expect(hits.map((e) => e.id)).toEqual(['1'])
  })

  it('matches description and resolved label', () => {
    expect(matchCalendarEvents(events, 'acme').map((e) => e.id)).toEqual(['1', '3'])
    expect(matchCalendarEvents(events, 'projecte').map((e) => e.id)).toEqual(['2'])
  })

  it('returns all events for empty query', () => {
    expect(matchCalendarEvents(events, '')).toHaveLength(3)
  })

  it('returns empty when nothing matches', () => {
    expect(matchCalendarEvents(events, 'zzzz')).toEqual([])
  })

  it('builds local anchor date from start_at', () => {
    expect(eventSearchAnchorDate(events[0]!)).toBe('2026-10-08')
    expect(eventSearchAnchorDate({ id: 'x', start_at: null })).toBeNull()
  })
})
