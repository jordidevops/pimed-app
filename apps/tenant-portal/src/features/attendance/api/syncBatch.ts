import type { LocalAttendanceOp } from '../db/attendanceDb'
import type { RecordPunchParams } from './attendanceService'

/** Lots petits (doc 15): 10–25 ops per crida. */
export const SYNC_BATCH_SIZE = 25

export type SyncPunchBatchItem = {
  id: string
  kind: 'punch'
  payload: {
    employee_id: string
    punch_type: string
    occurred_at: string
    geo?: RecordPunchParams['geo']
    location_permission?: string
    notes?: string | null
    source?: string
    pause_type?: string | null
    pause_counts_as_work?: boolean | null
    is_remote?: boolean
    geo_consent?: boolean
    geo_error?: string | null
    device_info?: Record<string, string> | null
  }
}

export type SyncPunchBatchResultItem = {
  client_op_id: string
  status: string
  server_id?: string | null
  message?: string | null
}

export function buildSyncPunchBatchItem(op: LocalAttendanceOp): SyncPunchBatchItem {
  return {
    id: op.client_op_id,
    kind: 'punch',
    payload: {
      employee_id: op.employee_id,
      punch_type: op.punch_type,
      occurred_at: op.occurred_at,
      geo: op.geo,
      location_permission: op.location_permission,
      notes: op.notes,
      source: op.source,
      pause_type: op.pause_type,
      pause_counts_as_work: op.pause_counts_as_work,
      is_remote: op.is_remote,
      geo_consent: op.geo_consent,
      geo_error: op.geo_error,
      device_info: op.device_info,
    },
  }
}

export function chunkOps<T>(ops: T[], size: number = SYNC_BATCH_SIZE): T[][] {
  if (size <= 0) return [ops]
  const chunks: T[][] = []
  for (let i = 0; i < ops.length; i += size) {
    chunks.push(ops.slice(i, i + size))
  }
  return chunks
}

export function isSyncSuccessStatus(status: string): boolean {
  return status === 'created' || status === 'duplicate' || status === 'accepted'
}
