import { describe, expect, it } from 'vitest'
import type { LocalAttendanceOp } from '../db/attendanceDb'
import { projectAttendancePunches } from '../utils/projectAttendancePunches'
import { derivePunchUiFromPunches } from '../utils/punchProfileUi'

function op(punchType: LocalAttendanceOp['punch_type'], occurredAt: string): LocalAttendanceOp {
  return {
    client_op_id: `op-${punchType}`,
    punch_type: punchType,
    employee_id: 'employee-1',
    tenant_id: 'tenant-1',
    user_id: 'user-1',
    occurred_at: occurredAt,
    source: 'web',
    status: 'pending',
    attempts: 0,
    created_at: occurredAt,
  }
}

describe('projectAttendancePunches', () => {
  it('applies a queued punch immediately to the visible state', () => {
    const projected = projectAttendancePunches(
      [{ punch_type: 'in', occurred_at: '2026-09-15T08:00:00Z' }],
      [op('break_start', '2026-09-15T10:00:00Z')],
    )

    expect(derivePunchUiFromPunches(projected, 'fixed_site', true).status).toBe('on_pause')
  })

  it('deduplicates a local operation already returned by the server', () => {
    const local = op('out', '2026-09-15T17:00:00Z')
    const projected = projectAttendancePunches(
      [
        { punch_type: 'in', occurred_at: '2026-09-15T08:00:00Z' },
        {
          punch_type: 'out',
          occurred_at: local.occurred_at,
          client_op_id: local.client_op_id,
        } as Parameters<typeof projectAttendancePunches>[0][number] & {
          client_op_id: string
        },
      ],
      [local],
    )

    expect(projected).toHaveLength(2)
    expect(derivePunchUiFromPunches(projected, 'fixed_site', true).status).toBe('outside')
  })
})
