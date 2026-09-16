import type { FieldOpsAdapter, LocalFieldOp } from '../../../lib/field-ops-db'

export interface FieldSyncItemResult {
  client_op_id: string
  status: 'created' | 'duplicate' | 'synced' | 'rejected' | 'retryable' | string
  server_id: string | null
  message: string | null
}

export async function applyFieldSyncResults(
  adapter: Pick<FieldOpsAdapter, 'markSynced' | 'markQuarantined' | 'markRetryable'>,
  batch: LocalFieldOp[],
  results: FieldSyncItemResult[],
): Promise<void> {
  for (const result of results) {
    const op = batch.find((item) => item.id === result.client_op_id)
    if (!op) continue

    if (
      result.status === 'created' ||
      result.status === 'duplicate' ||
      result.status === 'synced'
    ) {
      await adapter.markSynced(op.id, result.server_id ?? undefined)
    } else if (result.status === 'rejected') {
      await adapter.markQuarantined(op.id, result.message ?? 'rejected_by_server')
    } else {
      await adapter.markRetryable(op.id, result.message ?? result.status)
    }
  }
}
