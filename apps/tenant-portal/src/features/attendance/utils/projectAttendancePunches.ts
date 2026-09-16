import type { LocalAttendanceOp } from '../db/attendanceDb'
import type { PunchLike } from './punchProfileUi'

export function projectAttendancePunches(
  remotePunches: PunchLike[],
  localOps: LocalAttendanceOp[],
): PunchLike[] {
  const remoteClientIds = new Set(
    remotePunches
      .map((p) => (p as PunchLike & { client_op_id?: string | null }).client_op_id)
      .filter(Boolean),
  )
  const projectedLocal = localOps
    .filter((op) => !remoteClientIds.has(op.client_op_id))
    .map((op) => ({
      punch_type: op.punch_type,
      pause_type: op.pause_type ?? null,
      occurred_at: op.occurred_at,
      client_op_id: op.client_op_id,
    }))

  return [...remotePunches, ...projectedLocal].sort((a, b) =>
    (a.occurred_at ?? '').localeCompare(b.occurred_at ?? ''),
  )
}
