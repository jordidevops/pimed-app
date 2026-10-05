import { describe, expect, it } from 'vitest'
import {
  daysSpannedByEvent,
  projectEventsOntoDays,
  resolveEventColor,
} from './projectEventsOntoDays'

describe('daysSpannedByEvent', () => {
  const rangeStart = new Date(2026, 9, 1)
  const rangeEnd = new Date(2026, 9, 31)

  it('places a punctual event on its start day', () => {
    expect(
      daysSpannedByEvent(
        { id: '1', start: '2026-10-05T09:00:00' },
        rangeStart,
        rangeEnd,
      ),
    ).toEqual(['2026-10-05'])
  })

  it('projects timed multiday inclusively on start and end days', () => {
    expect(
      daysSpannedByEvent(
        {
          id: '1',
          start: '2026-10-05T09:00:00',
          end: '2026-10-07T18:00:00',
        },
        rangeStart,
        rangeEnd,
      ),
    ).toEqual(['2026-10-05', '2026-10-06', '2026-10-07'])
  })

  it('treats midnight end as exclusive for all-day events', () => {
    expect(
      daysSpannedByEvent(
        {
          id: '1',
          start: '2026-10-05T00:00:00',
          end: '2026-10-08T00:00:00',
          allDay: true,
        },
        rangeStart,
        rangeEnd,
      ),
    ).toEqual(['2026-10-05', '2026-10-06', '2026-10-07'])
  })

  it('clips to the visible range', () => {
    expect(
      daysSpannedByEvent(
        {
          id: '1',
          start: '2026-09-28T10:00:00',
          end: '2026-10-03T18:00:00',
        },
        new Date(2026, 9, 1),
        new Date(2026, 9, 2),
      ),
    ).toEqual(['2026-10-01', '2026-10-02'])
  })
})

describe('projectEventsOntoDays', () => {
  it('lists the same event under each overlapping day', () => {
    const map = projectEventsOntoDays(
      [
        {
          id: 'trip',
          start: '2026-10-05T00:00:00',
          end: '2026-10-07T00:00:00',
          allDay: true,
        },
      ],
      new Date(2026, 9, 1),
      new Date(2026, 9, 31),
    )
    expect(map.get('2026-10-05')?.[0]?.id).toBe('trip')
    expect(map.get('2026-10-06')?.[0]?.id).toBe('trip')
    expect(map.has('2026-10-07')).toBe(false)
  })
})

describe('resolveEventColor', () => {
  it('accepts hex and falls back otherwise', () => {
    expect(resolveEventColor('#3b82f6')).toBe('#3b82f6')
    expect(resolveEventColor('blue')).toBe('#6366f1')
    expect(resolveEventColor(null, '#111111')).toBe('#111111')
  })
})
