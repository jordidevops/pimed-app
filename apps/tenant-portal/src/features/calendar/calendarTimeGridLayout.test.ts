import { describe, expect, it } from 'vitest'
import {
  clipTimedEventToDay,
  dateAtMinutes,
  isAllDayEvent,
  layoutTimedEventsForDay,
  minutesFromMidnight,
  SLOT_MINUTES,
} from './calendarTimeGridLayout'

describe('calendarTimeGridLayout', () => {
  const day = new Date(2026, 9, 8) // local Oct 8

  it('computes minutes from midnight', () => {
    expect(minutesFromMidnight(new Date(2026, 9, 8, 9, 30))).toBe(9 * 60 + 30)
  })

  it('detects all-day events', () => {
    expect(
      isAllDayEvent({
        id: '1',
        start: new Date(2026, 9, 8).toISOString(),
        end: new Date(2026, 9, 9).toISOString(),
        allDay: true,
      }),
    ).toBe(true)
    expect(
      isAllDayEvent({
        id: '2',
        start: new Date(2026, 9, 8, 10, 0).toISOString(),
        allDay: false,
      }),
    ).toBe(false)
  })

  it('clips timed events to the local day', () => {
    const span = clipTimedEventToDay(
      {
        id: 'a',
        start: new Date(2026, 9, 8, 10, 0).toISOString(),
        end: new Date(2026, 9, 8, 11, 0).toISOString(),
      },
      day,
    )
    expect(span).toEqual({ startMin: 600, endMin: 660 })
  })

  it('clips overnight timed events to day bounds', () => {
    const span = clipTimedEventToDay(
      {
        id: 'b',
        start: new Date(2026, 9, 7, 22, 0).toISOString(),
        end: new Date(2026, 9, 8, 2, 0).toISOString(),
      },
      day,
    )
    expect(span?.startMin).toBe(0)
    expect(span?.endMin).toBe(120)
  })

  it('packs overlapping events into columns', () => {
    const rects = layoutTimedEventsForDay(
      [
        {
          id: 'a',
          start: new Date(2026, 9, 8, 10, 0).toISOString(),
          end: new Date(2026, 9, 8, 11, 0).toISOString(),
        },
        {
          id: 'b',
          start: new Date(2026, 9, 8, 10, 30).toISOString(),
          end: new Date(2026, 9, 8, 11, 30).toISOString(),
        },
        {
          id: 'c',
          start: new Date(2026, 9, 8, 13, 0).toISOString(),
          end: new Date(2026, 9, 8, 14, 0).toISOString(),
        },
      ],
      day,
    )
    const byId = Object.fromEntries(rects.map((r) => [r.id, r]))
    expect(byId.a?.columnCount).toBe(2)
    expect(byId.b?.columnCount).toBe(2)
    expect(byId.a?.column).not.toBe(byId.b?.column)
    expect(byId.c?.columnCount).toBe(1)
  })

  it('builds slot start datetimes', () => {
    const d = dateAtMinutes(day, 9 * 60 + SLOT_MINUTES)
    expect(d.getHours()).toBe(9)
    expect(d.getMinutes()).toBe(30)
  })
})
