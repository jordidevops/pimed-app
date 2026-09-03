export const PUNCH_DISCREPANCY_TOLERANCE_OPTIONS = [15, 30, 45, 60] as const

export type PunchDiscrepancyToleranceMinutes =
  (typeof PUNCH_DISCREPANCY_TOLERANCE_OPTIONS)[number]

export const DEFAULT_PUNCH_DISCREPANCY_TOLERANCE_MIN = 15

export function parsePunchDiscrepancyToleranceMinutes(
  effective: Record<string, unknown>,
): PunchDiscrepancyToleranceMinutes {
  const raw = Number(effective.attendance_punch_discrepancy_tolerance_minutes)
  if (PUNCH_DISCREPANCY_TOLERANCE_OPTIONS.includes(raw as PunchDiscrepancyToleranceMinutes)) {
    return raw as PunchDiscrepancyToleranceMinutes
  }
  return DEFAULT_PUNCH_DISCREPANCY_TOLERANCE_MIN
}

export function punchDiscrepancySettingsPayload(
  toleranceMinutes: PunchDiscrepancyToleranceMinutes,
): Record<string, unknown> {
  return { attendance_punch_discrepancy_tolerance_minutes: toleranceMinutes }
}
