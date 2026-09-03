export const locationsKeys = {
  all: (tenantId: string) => ['locations', tenantId] as const,
  list: (tenantId: string, siteId?: string | null) =>
    [...locationsKeys.all(tenantId), 'list', siteId ?? 'all'] as const,
  attendanceAssignments: (locationId: string, includeInactive = false) =>
    ['locations', 'attendance-assignments', locationId, includeInactive ? 'all' : 'active'] as const,
}
