export const EFFECTIVE_TIME_ENABLED_KEY = 'attendance_effective_time_enabled'

export function parseEffectiveTimeEnabled(
  effective: Record<string, unknown> | undefined | null,
): boolean {
  return effective?.[EFFECTIVE_TIME_ENABLED_KEY] === true
}

export function effectiveTimeSettingsPayload(enabled: boolean): Record<string, unknown> {
  return { [EFFECTIVE_TIME_ENABLED_KEY]: enabled }
}
