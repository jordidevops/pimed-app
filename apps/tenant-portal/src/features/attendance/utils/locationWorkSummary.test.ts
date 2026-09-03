import { describe, expect, it } from 'vitest'
import type { TimePunch } from '../api/attendanceService'
import { aggregateLocationWorkSummary } from './locationWorkSummary'

function punch(partial: Partial<TimePunch> & Pick<TimePunch, 'punch_type' | 'occurred_at'>): TimePunch {
  return {
    employee_id: 'emp-1',
    location_id: 'loc-a',
    location_name_snapshot: 'Cuina',
    ...partial,
  } as TimePunch
}

describe('aggregateLocationWorkSummary', () => {
  it('sums a closed in/out interval at the punch location', () => {
    const rows = aggregateLocationWorkSummary(
      [
        punch({ punch_type: 'in', occurred_at: '2026-07-14T06:00:00.000Z' }),
        punch({ punch_type: 'out', occurred_at: '2026-07-14T14:00:00.000Z' }),
      ],
      { 'emp-1': 'Anna Test' },
    )

    expect(rows).toHaveLength(1)
    expect(rows[0]?.employee_name).toBe('Anna Test')
    expect(rows[0]?.location_name).toBe('Cuina')
    expect(rows[0]?.work_minutes).toBe(480)
    expect(rows[0]?.interval_count).toBe(1)
    expect(rows[0]?.open_interval_count).toBe(0)
  })

  it('subtracts break time between in and out', () => {
    const rows = aggregateLocationWorkSummary(
      [
        punch({ punch_type: 'in', occurred_at: '2026-07-14T06:00:00.000Z' }),
        punch({ punch_type: 'break_start', occurred_at: '2026-07-14T10:00:00.000Z' }),
        punch({ punch_type: 'break_end', occurred_at: '2026-07-14T11:00:00.000Z' }),
        punch({ punch_type: 'out', occurred_at: '2026-07-14T15:00:00.000Z' }),
      ],
      { 'emp-1': 'Anna Test' },
    )

    expect(rows[0]?.work_minutes).toBe(480)
    expect(rows[0]?.interval_count).toBe(2)
  })

  it('groups multiple locations for the same employee', () => {
    const rows = aggregateLocationWorkSummary(
      [
        punch({
          punch_type: 'in',
          occurred_at: '2026-07-14T06:00:00.000Z',
          location_id: 'loc-a',
          location_name_snapshot: 'Cuina',
        }),
        punch({
          punch_type: 'out',
          occurred_at: '2026-07-14T10:00:00.000Z',
          location_id: 'loc-a',
          location_name_snapshot: 'Cuina',
        }),
        punch({
          punch_type: 'in',
          occurred_at: '2026-07-14T10:30:00.000Z',
          location_id: 'loc-b',
          location_name_snapshot: 'Sala',
        }),
        punch({
          punch_type: 'out',
          occurred_at: '2026-07-14T14:30:00.000Z',
          location_id: 'loc-b',
          location_name_snapshot: 'Sala',
        }),
      ],
      { 'emp-1': 'Anna Test' },
    )

    expect(rows).toHaveLength(2)
    const cuina = rows.find((row) => row.location_name === 'Cuina')
    const sala = rows.find((row) => row.location_name === 'Sala')
    expect(cuina?.work_minutes).toBe(240)
    expect(sala?.work_minutes).toBe(240)
  })

  it('marks open intervals without counting minutes', () => {
    const rows = aggregateLocationWorkSummary(
      [punch({ punch_type: 'in', occurred_at: '2026-07-14T06:00:00.000Z' })],
      { 'emp-1': 'Anna Test' },
    )

    expect(rows[0]?.work_minutes).toBe(0)
    expect(rows[0]?.open_interval_count).toBe(1)
  })

  it('uses Sense ubicació when snapshot is missing', () => {
    const rows = aggregateLocationWorkSummary(
      [
        punch({
          punch_type: 'in',
          occurred_at: '2026-07-14T06:00:00.000Z',
          location_id: null,
          location_name_snapshot: null,
        }),
        punch({
          punch_type: 'out',
          occurred_at: '2026-07-14T08:00:00.000Z',
          location_id: null,
          location_name_snapshot: null,
        }),
      ],
      { 'emp-1': 'Anna Test' },
    )

    expect(rows[0]?.location_name).toBe('Sense ubicació')
    expect(rows[0]?.work_minutes).toBe(120)
  })
})
