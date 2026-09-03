import {
  DEFAULT_PUNCH_DISCREPANCY_TOLERANCE_MIN,
  parsePunchDiscrepancyToleranceMinutes,
  punchDiscrepancySettingsPayload,
  type PunchDiscrepancyToleranceMinutes,
} from './punchDiscrepancySettings'
import { parseEffectiveTimeEnabled } from './effectiveTimeSettings'

export const TRUST_SCHEDULE_HOURS_CLAIM_KEY = 'attendance_trust_schedule_hours_claim'

export interface ApprovalAssistSettings {
  trustScheduleHoursClaim: boolean
  effectiveTimeEnabled: boolean
  toleranceMinutes: PunchDiscrepancyToleranceMinutes
}

export function parseApprovalAssistSettings(
  effective: Record<string, unknown> | undefined | null,
): ApprovalAssistSettings {
  const raw = effective ?? {}
  return {
    trustScheduleHoursClaim: raw[TRUST_SCHEDULE_HOURS_CLAIM_KEY] === true,
    effectiveTimeEnabled: parseEffectiveTimeEnabled(raw),
    toleranceMinutes: parsePunchDiscrepancyToleranceMinutes(raw),
  }
}

export function approvalAssistSettingsPayload(
  settings: ApprovalAssistSettings,
): Record<string, unknown> {
  return {
    ...punchDiscrepancySettingsPayload(settings.toleranceMinutes),
    [TRUST_SCHEDULE_HOURS_CLAIM_KEY]: settings.trustScheduleHoursClaim,
  }
}

export { DEFAULT_PUNCH_DISCREPANCY_TOLERANCE_MIN }
