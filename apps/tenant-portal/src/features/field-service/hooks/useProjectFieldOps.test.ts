import { describe, expect, it } from 'vitest'
import type { LocalFieldOp } from '../../../lib/field-ops-db'
import { projectFieldProjection } from '../utils/projectFieldProjection'

function actual(id: string, quantity: number): LocalFieldOp {
  return {
    id,
    tenant_id: 'tenant',
    project_id: 'project',
    kind: 'project_line.actual',
    status: 'pending',
    created_at: `2026-01-01T00:00:0${quantity}.000Z`,
    retry_count: 0,
    payload: {
      project_id: 'project',
      line_id: 'line',
      unit: 'h',
      quantity,
    },
  }
}

describe('project field projection', () => {
  it('uses the latest pending actual for each line', () => {
    const projection = projectFieldProjection([actual('old', 2), actual('new', 3)])
    expect(projection.lineActuals.get('line')?.payload.quantity).toBe(3)
  })

  it('maps a permanent close error to action_required', () => {
    const close: LocalFieldOp = {
      id: 'close',
      tenant_id: 'tenant',
      project_id: 'project',
      kind: 'project.close_out',
      status: 'quarantined',
      created_at: '2026-01-01T00:00:00.000Z',
      retry_count: 0,
      last_error: 'consumer_overage_requires_amendment',
      payload: { project_id: 'project' },
    }
    const projection = projectFieldProjection([actual('line-op', 2), close])
    expect(projection.closeState).toBe('action_required')
    expect(projection.dependencyIds).toEqual(['line-op'])
  })

  it('does not silently release a close-out whose dependency disappeared', () => {
    const close: LocalFieldOp = {
      id: 'close',
      tenant_id: 'tenant',
      project_id: 'project',
      kind: 'project.close_out',
      status: 'pending',
      depends_on: ['missing-material'],
      created_at: '2026-01-01T00:00:01.000Z',
      retry_count: 0,
      payload: { project_id: 'project' },
    }

    const projection = projectFieldProjection([close])
    expect(projection.closeState).toBe('action_required')
    expect(projection.missingDependencyId).toBe('missing-material')
  })
})
