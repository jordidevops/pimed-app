export const departmentsKeys = {
  all: (tenantId: string) => ['departments', tenantId] as const,
  list: (tenantId: string) => [...departmentsKeys.all(tenantId), 'list'] as const,
}
