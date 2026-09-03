export const employeesKeys = {
  all: (tenantId: string) => ['employees', tenantId] as const,
  list: (tenantId: string) => [...employeesKeys.all(tenantId), 'list'] as const,
}
