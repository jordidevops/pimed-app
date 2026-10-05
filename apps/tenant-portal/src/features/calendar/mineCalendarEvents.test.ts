import { describe, expect, it } from 'vitest'
import {
  collectTaskEntityIds,
  filterMyCalendarEvents,
  isMyCalendarEvent,
} from './mineCalendarEvents'

const me = 'user-me'
const other = 'user-other'
const myEmp = 'emp-me'

describe('mineCalendarEvents', () => {
  it('manual: only owner', () => {
    expect(
      isMyCalendarEvent(
        { id: '1', entity_type: 'manual', owner_id: me },
        { userId: me, myEmployeeId: myEmp },
      ),
    ).toBe(true)
    expect(
      isMyCalendarEvent(
        { id: '2', entity_type: 'manual', owner_id: other },
        { userId: me, myEmployeeId: myEmp },
      ),
    ).toBe(false)
  })

  it('shift_slot: matches metadata.employee_id', () => {
    expect(
      isMyCalendarEvent(
        {
          id: 's1',
          entity_type: 'shift_slot',
          metadata: { employee_id: myEmp },
        },
        { userId: me, myEmployeeId: myEmp },
      ),
    ).toBe(true)
    expect(
      isMyCalendarEvent(
        {
          id: 's2',
          entity_type: 'shift_slot',
          metadata: { employee_id: 'emp-other' },
        },
        { userId: me, myEmployeeId: myEmp },
      ),
    ).toBe(false)
  })

  it('task: uses assignee lookup, not owner', () => {
    const map = new Map<string, string | null>([['task-1', me], ['task-2', other]])
    expect(
      isMyCalendarEvent(
        { id: 'e1', entity_type: 'task', entity_id: 'task-1', owner_id: other },
        { userId: me, myEmployeeId: myEmp, taskAssigneeById: map },
      ),
    ).toBe(true)
    expect(
      isMyCalendarEvent(
        { id: 'e2', entity_type: 'task', entity_id: 'task-2', owner_id: me },
        { userId: me, myEmployeeId: myEmp, taskAssigneeById: map },
      ),
    ).toBe(false)
  })

  it('task: metadata assignee_id fallback', () => {
    expect(
      isMyCalendarEvent(
        {
          id: 'e3',
          entity_type: 'task',
          entity_id: 'task-x',
          metadata: { assignee_id: me },
        },
        { userId: me, myEmployeeId: myEmp },
      ),
    ).toBe(true)
  })

  it('project: never mine in V2.2', () => {
    expect(
      isMyCalendarEvent(
        { id: 'p1', entity_type: 'project', owner_id: me },
        { userId: me, myEmployeeId: myEmp },
      ),
    ).toBe(false)
  })

  it('filters lists and collects task ids', () => {
    const events = [
      { id: '1', entity_type: 'manual' as const, owner_id: me },
      { id: '2', entity_type: 'manual' as const, owner_id: other },
      { id: '3', entity_type: 'task' as const, entity_id: 't1', owner_id: me },
    ]
    expect(
      filterMyCalendarEvents(events, { userId: me, myEmployeeId: myEmp }).map((e) => e.id),
    ).toEqual(['1'])
    expect(collectTaskEntityIds(events)).toEqual(['t1'])
  })
})
