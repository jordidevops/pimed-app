export const employeePortalKeys = {
  tokens: (employeeId: string) => ['employee-portal-tokens', employeeId] as const,
  accessLogs: (tokenId: string) => ['employee-portal-access-logs', tokenId] as const,
  overview: (query: Record<string, unknown>) => ['employee-portal-overview', query] as const,
}
