import Dexie, { type Table } from 'dexie'

export type PunchOpStatus = 'pending' | 'synced' | 'quarantined'

export type PunchType =
  | 'in'
  | 'out'
  | 'break_start'
  | 'break_end'
  | 'day_start'
  | 'day_end'
  | 'travel_start'
  | 'travel_end'

export interface LocalAttendanceOp {
  localId?: number
  client_op_id: string
  punch_type: PunchType
  employee_id: string
  tenant_id: string
  user_id: string
  occurred_at: string
  geo?: {
    lat: number
    lng: number
    accuracy: number
    altitude?: number | null
    speed?: number | null
  } | null
  location_permission?: string
  notes?: string | null
  source: string
  pause_type?: string | null
  pause_counts_as_work?: boolean | null
  is_remote?: boolean
  geo_consent?: boolean
  geo_error?: string | null
  device_info?: Record<string, string> | null
  status: PunchOpStatus
  attempts: number
  created_at: string
  error?: string | null
}

export interface SyncState {
  id: 1
  last_synced_at: string | null
}

class AttendanceDatabase extends Dexie {
  attendance_ops!: Table<LocalAttendanceOp, number>
  sync_state!: Table<SyncState, number>

  constructor() {
    super('pime_attendance')

    this.version(1).stores({
      attendance_ops: '++localId, &client_op_id, status, created_at',
      sync_state: 'id',
    })

    this.version(2).stores({
      attendance_ops:
        '++localId, &client_op_id, employee_id, [employee_id+status], status, created_at',
      sync_state: 'id',
    })

    this.version(3).stores({
      attendance_ops:
        '++localId, &client_op_id, tenant_id, employee_id, [tenant_id+employee_id+status], [employee_id+status], status, created_at',
      sync_state: 'id',
    })

    this.version(4).stores({
      attendance_ops:
        '++localId, &client_op_id, tenant_id, employee_id, [tenant_id+employee_id+status], [employee_id+status], status, created_at',
      sync_state: 'id',
    })
  }
}

export const attendanceDb = new AttendanceDatabase()

export async function savePunchOpLocally(
  op: Omit<LocalAttendanceOp, 'localId' | 'status' | 'attempts' | 'created_at'>,
): Promise<void> {
  await attendanceDb.attendance_ops.add({
    ...op,
    status: 'pending',
    attempts: 0,
    created_at: new Date().toISOString(),
  })
}

export async function getPendingOps(
  tenantId: string,
  employeeId: string,
): Promise<LocalAttendanceOp[]> {
  return attendanceDb.attendance_ops
    .where('[tenant_id+employee_id+status]')
    .equals([tenantId, employeeId, 'pending'])
    .toArray()
}

export async function markOpSynced(client_op_id: string): Promise<void> {
  await attendanceDb.attendance_ops
    .where('client_op_id')
    .equals(client_op_id)
    .modify({ status: 'synced' })
}

export async function markOpFailed(
  client_op_id: string,
  error: string,
  attempts: number,
): Promise<void> {
  const newStatus: PunchOpStatus = attempts >= 5 ? 'quarantined' : 'pending'
  await attendanceDb.attendance_ops
    .where('client_op_id')
    .equals(client_op_id)
    .modify({ status: newStatus, attempts, error })
}

export async function getPendingCount(tenantId: string, employeeId: string): Promise<number> {
  return attendanceDb.attendance_ops
    .where('[tenant_id+employee_id+status]')
    .equals([tenantId, employeeId, 'pending'])
    .count()
}

export async function getQuarantinedCount(tenantId: string, employeeId: string): Promise<number> {
  return attendanceDb.attendance_ops
    .where('[tenant_id+employee_id+status]')
    .equals([tenantId, employeeId, 'quarantined'])
    .count()
}

export async function updateSyncState(): Promise<void> {
  await attendanceDb.sync_state.put({ id: 1, last_synced_at: new Date().toISOString() })
}

export async function getSyncState(): Promise<SyncState | undefined> {
  return attendanceDb.sync_state.get(1)
}
