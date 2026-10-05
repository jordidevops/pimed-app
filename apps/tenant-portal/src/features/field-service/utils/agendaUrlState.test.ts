import { describe, expect, it } from 'vitest'
import {
  hasActiveAgendaFilters,
  parseAgendaUrlState,
  serializeAgendaUrlState,
} from './agendaUrlState'

describe('agendaUrlState', () => {
  it('round-trips filters in the URL', () => {
    const defaults = { defaultView: 'week' as const, defaultScope: 'all' as const }
    const state = parseAgendaUrlState(
      new URLSearchParams('view=month&scope=mine&types=work_order&status=active&tech=u1,u2&tray=1'),
      defaults,
    )
    expect(state).toEqual({
      view: 'month',
      scope: 'mine',
      types: ['work_order'],
      statuses: ['active'],
      memberIds: ['u1', 'u2'],
      anchor: null,
      tray: true,
    })
    expect(hasActiveAgendaFilters(state)).toBe(true)
    expect(serializeAgendaUrlState(state, defaults).toString()).toBe(
      'view=month&scope=mine&types=work_order&status=active&tech=u1%2Cu2&tray=1',
    )
  })

  it('omits default view/scope/types from serialized params', () => {
    const defaults = { defaultView: 'list' as const, defaultScope: 'mine' as const }
    const state = parseAgendaUrlState(new URLSearchParams(), defaults)
    expect(serializeAgendaUrlState(state, defaults).toString()).toBe('')
    expect(hasActiveAgendaFilters(state)).toBe(false)
  })

  it('parses day view', () => {
    const defaults = { defaultView: 'week' as const, defaultScope: 'all' as const }
    const state = parseAgendaUrlState(
      new URLSearchParams('view=day&anchor=2026-10-08'),
      defaults,
    )
    expect(state.view).toBe('day')
    expect(state.anchor).toBe('2026-10-08')
  })
})
