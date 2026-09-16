export interface WorkLogDurationRow {
  check_in: string | null
  check_out: string | null
  duration_minutes: number | null
}

export function workLogRowSeconds(
  row: WorkLogDurationRow,
  nowMs = Date.now(),
): number {
  if (row.check_in && row.check_out) {
    return Math.max(
      0,
      Math.floor(
        (new Date(row.check_out).getTime() - new Date(row.check_in).getTime()) /
          1000,
      ),
    )
  }
  if (row.duration_minutes != null && row.check_out) {
    return Math.max(0, row.duration_minutes * 60)
  }
  if (row.check_in && !row.check_out) {
    return Math.max(
      0,
      Math.floor((nowMs - new Date(row.check_in).getTime()) / 1000),
    )
  }
  return 0
}
