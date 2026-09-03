export const emailKeys = {
  config: (tenantId: string) => ['email', 'config', tenantId] as const,
  siteConfig: (siteId: string) => ['email', 'siteConfig', siteId] as const,
  domains: (tenantId: string) => ['email', 'domains', tenantId] as const,
  logs: (tenantId: string, params: object) =>
    ['email', 'logs', tenantId, params] as const,
  usage: (tenantId: string) => ['email', 'usage', tenantId] as const,
  templates: (tenantId: string) => ['email', 'templates', tenantId] as const,
  layouts: (tenantId: string) => ['email', 'layouts', tenantId] as const,
}
