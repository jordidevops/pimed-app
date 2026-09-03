export type AttendanceGeoEnabledFormValue = 'inherit' | 'true' | 'false'

export function toAttendanceGeoEnabledFormValue(
  value: boolean | null | undefined,
): AttendanceGeoEnabledFormValue {
  if (value === true) return 'true'
  if (value === false) return 'false'
  return 'inherit'
}

export function fromAttendanceGeoEnabledFormValue(
  value: AttendanceGeoEnabledFormValue,
): boolean | null {
  if (value === 'true') return true
  if (value === 'false') return false
  return null
}

export function parseTenantAttendanceGeoEnabled(
  effective: Record<string, unknown>,
): boolean {
  if (
    effective.attendance_geo_enabled !== undefined
    && effective.attendance_geo_enabled !== null
  ) {
    return effective.attendance_geo_enabled === true
  }
  return effective.attendance_location_consent_required === true
}

export function attendanceGeoSettingsPayload(enabled: boolean): Record<string, unknown> {
  return { attendance_geo_enabled: enabled }
}
