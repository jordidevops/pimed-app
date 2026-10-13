import { describe, expect, it } from 'vitest'
import { placeVisitsOnDays, visitTimeLabelsForDay } from './agendaVisitDisplay'
import type { FieldVisit } from '../api/fieldVisitsService'

function visit(partial: Partial<FieldVisit> & Pick<FieldVisit, 'id' | 'planned_start'>): FieldVisit {
  return {
    type: 'work_order',
    name: 'OS',
    status: 'active',
    planned_end: null,
    client_display_name: null,
    contact_site_name: null,
    contact_site_city: null,
    service_mode: null,
    commercial_regime: null,
    members: [],
    ...partial,
  }
}

describe('placeVisitsOnDays', () => {
  it('places a multi-day visit on each overlapping day', () => {
    const map = placeVisitsOnDays(
      [
        visit({
          id: 'a',
          planned_start: '2026-10-14T09:00:00',
          planned_end: '2026-10-16T11:00:00',
        }),
      ],
      new Date(2026, 9, 14),
      new Date(2026, 9, 16),
    )
    expect(map.get('2026-10-14')?.[0]?.continuesTo).toBe(true)
    expect(map.get('2026-10-15')?.[0]?.continuesFrom).toBe(true)
    expect(map.get('2026-10-15')?.[0]?.continuesTo).toBe(true)
    expect(map.get('2026-10-16')?.[0]?.continuesFrom).toBe(true)
    expect(map.get('2026-10-16')?.[0]?.continuesTo).toBe(false)
  })
})

describe('visitTimeLabelsForDay', () => {
  it('shows end date when the visit ends on another day', () => {
    const labels = visitTimeLabelsForDay(
      visit({
        id: 'a',
        planned_start: '2026-10-14T09:00:00',
        planned_end: '2026-10-15T11:30:00',
      }),
      new Date(2026, 9, 14),
      'ca',
    )
    expect(labels.startLabel).toMatch(/09/)
    expect(labels.continuesTo).toBe(true)
    expect(labels.endLabel).toContain('→')
  })

  it('marks continuation on the middle day', () => {
    const labels = visitTimeLabelsForDay(
      visit({
        id: 'a',
        planned_start: '2026-10-14T09:00:00',
        planned_end: '2026-10-16T11:00:00',
      }),
      new Date(2026, 9, 15),
      'ca',
    )
    expect(labels.continuesFrom).toBe(true)
    expect(labels.continuesTo).toBe(true)
    expect(labels.startLabel).toBe('…')
  })
})
