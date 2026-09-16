import { describe, expect, it, vi } from 'vitest'
import type { LocalFieldOp } from '../../../lib/field-ops-db'
import { applyFieldSyncResults } from './processFieldSyncResults'

function op(id: string): LocalFieldOp {
  return {
    id,
    tenant_id: 'tenant',
    project_id: 'project',
    kind: 'worklog.start',
    status: 'syncing',
    created_at: '2026-01-01T00:00:00.000Z',
    retry_count: 0,
    payload: {
      project_id: 'project',
      project_name: 'OS',
      occurred_at: '2026-01-01T00:00:00.000Z',
    },
  }
}

describe('applyFieldSyncResults', () => {
  it('keeps transients retryable instead of quarantining them', async () => {
    const adapter = {
      markSynced: vi.fn(),
      markQuarantined: vi.fn(),
      markRetryable: vi.fn(),
    }

    await applyFieldSyncResults(
      adapter,
      [op('ok'), op('busy'), op('bad')],
      [
        { client_op_id: 'ok', status: 'created', server_id: 'wl-1', message: null },
        { client_op_id: 'busy', status: 'retryable', server_id: null, message: 'deadlock detected' },
        { client_op_id: 'bad', status: 'rejected', server_id: null, message: 'project_already_closed' },
      ],
    )

    expect(adapter.markSynced).toHaveBeenCalledWith('ok', 'wl-1')
    expect(adapter.markRetryable).toHaveBeenCalledWith('busy', 'deadlock detected')
    expect(adapter.markQuarantined).toHaveBeenCalledWith('bad', 'project_already_closed')
  })
})
