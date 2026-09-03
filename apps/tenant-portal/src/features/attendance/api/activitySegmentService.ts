import { supabase } from '@/lib/supabase'

export type ActivityKind =
  | 'WORK'
  | 'TRAVEL'
  | 'BREAK_PAID'
  | 'BREAK_UNPAID'
  | 'OFF_DUTY'
  | 'STANDBY'

export interface ActivitySegment {
  id: string
  activity_kind: ActivityKind
  started_at: string
  ended_at: string | null
  source_punch_ids: string[]
  flags_snapshot: Record<string, unknown>
}

function parseSegment(raw: unknown): ActivitySegment | null {
  if (!raw || typeof raw !== 'object') return null
  const row = raw as Record<string, unknown>
  const id = row.id
  const kind = row.activity_kind
  const startedAt = row.started_at
  if (typeof id !== 'string' || typeof kind !== 'string' || typeof startedAt !== 'string') {
    return null
  }
  return {
    id,
    activity_kind: kind as ActivityKind,
    started_at: startedAt,
    ended_at: typeof row.ended_at === 'string' ? row.ended_at : null,
    source_punch_ids: Array.isArray(row.source_punch_ids)
      ? row.source_punch_ids.filter((x): x is string => typeof x === 'string')
      : [],
    flags_snapshot:
      row.flags_snapshot && typeof row.flags_snapshot === 'object'
        ? (row.flags_snapshot as Record<string, unknown>)
        : {},
  }
}

/** Segments d'activitat consolidats per a un dia (RPC G1b). */
export async function fetchActivitySegments(
  employeeId: string,
  workDate: string,
): Promise<ActivitySegment[]> {
  const { data, error } = await supabase.rpc('get_activity_segments', {
    p_employee_id: employeeId,
    p_work_date: workDate,
  })
  if (error) throw new Error(error.message)
  if (!Array.isArray(data)) return []
  return data.map(parseSegment).filter((s): s is ActivitySegment => s !== null)
}

export function segmentDurationMinutes(segment: ActivitySegment): number {
  if (!segment.ended_at) return 0
  const start = new Date(segment.started_at).getTime()
  const end = new Date(segment.ended_at).getTime()
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return 0
  return Math.round((end - start) / 60_000)
}
