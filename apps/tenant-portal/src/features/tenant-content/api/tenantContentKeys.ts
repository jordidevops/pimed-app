export const tenantContentKeys = {
  all: (tenantId: string) => ['tenant-content', tenantId] as const,
  list: (tenantId: string, filters: Record<string, unknown>) =>
    [...tenantContentKeys.all(tenantId), 'list', filters] as const,
  detail: (tenantId: string, itemId: string) =>
    [...tenantContentKeys.all(tenantId), 'detail', itemId] as const,
  usage: (tenantId: string) => [...tenantContentKeys.all(tenantId), 'usage'] as const,
  reach: (tenantId: string, itemId: string) =>
    [...tenantContentKeys.all(tenantId), 'reach', itemId] as const,
}
