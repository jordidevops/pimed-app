export interface WorkedPunchLike {
  punch_type?: string | null
  occurred_at?: string | null
}

/** Net worked milliseconds from punch pairs, including an open `in` interval. */
export function liveWorkedMs(punches: WorkedPunchLike[], now: number): number {
  let total = 0
  let startedAt: number | null = null
  for (const punch of punches) {
    const at = punch.occurred_at ? new Date(punch.occurred_at).getTime() : NaN
    if (!Number.isFinite(at)) continue
    if (punch.punch_type === 'in' || punch.punch_type === 'break_end') {
      startedAt = at
    } else if (
      (punch.punch_type === 'out' || punch.punch_type === 'break_start') &&
      startedAt != null
    ) {
      total += Math.max(0, at - startedAt)
      startedAt = null
    }
  }
  return total + (startedAt == null ? 0 : Math.max(0, now - startedAt))
}

export function formatWorkedCounter(ms: number, running: boolean): string {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000))
  const hours = Math.floor(totalSeconds / 3600)
  const minutes = Math.floor((totalSeconds % 3600) / 60)
  const seconds = totalSeconds % 60
  const hhmm = `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`
  if (!running) return hhmm
  return `${hhmm}:${String(seconds).padStart(2, '0')}`
}
