const storageKey = (userId: string, tenantId: string) =>
  `operationsLastDashboardAt_${userId}_${tenantId}`

/** ISO timestamp of the previous dashboard visit (null = first visit). */
export function getOperationsDashboardSeenAt(
  userId: string | undefined,
  tenantId: string | undefined,
): string | null {
  if (!userId || !tenantId) return null
  return localStorage.getItem(storageKey(userId, tenantId))
}

export function markOperationsDashboardSeen(userId: string, tenantId: string): void {
  localStorage.setItem(storageKey(userId, tenantId), new Date().toISOString())
}
