// Query key factory for public-portal feature
export const publicPortalKeys = {
  all: ['public-portal'] as const,
  site: (tenantId: string) => [...publicPortalKeys.all, 'site', tenantId] as const,
  pages: (tenantId: string, siteId?: string) =>
    [...publicPortalKeys.all, 'pages', tenantId, siteId] as const,
  domains: (tenantId: string, siteId?: string) =>
    [...publicPortalKeys.all, 'domains', tenantId, siteId] as const,
  leads: (tenantId: string, filters?: Record<string, unknown>) =>
    [...publicPortalKeys.all, 'leads', tenantId, filters] as const,
}
