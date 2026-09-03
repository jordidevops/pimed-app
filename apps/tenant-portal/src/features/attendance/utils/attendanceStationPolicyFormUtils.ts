export function parseTenantPunchOnlyAtStations(
  effective: Record<string, unknown>,
): boolean {
  return effective.punch_only_at_stations === true
}

export function punchOnlyAtStationsPayload(enabled: boolean): Record<string, unknown> {
  return { punch_only_at_stations: enabled }
}
