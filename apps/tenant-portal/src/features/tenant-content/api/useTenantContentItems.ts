import { useQuery } from '@tanstack/react-query'
import {
  getTenantContentItem,
  getTenantContentUsage,
  listPublicSitesForTenant,
  listTenantContentItems,
  previewTenantContentReach,
} from './tenantContentService'
import { tenantContentKeys } from './tenantContentKeys'
import type { ContentListFilters } from './tenantContentTypes'

export function useTenantContentItems(
  tenantId: string | null | undefined,
  filters: ContentListFilters = {},
) {
  return useQuery({
    queryKey: tenantContentKeys.list(tenantId ?? '', filters),
    enabled: !!tenantId,
    queryFn: () => listTenantContentItems(tenantId!, filters),
    staleTime: 20_000,
  })
}

export function useTenantContentItem(
  tenantId: string | null | undefined,
  itemId: string | null | undefined,
) {
  return useQuery({
    queryKey: tenantContentKeys.detail(tenantId ?? '', itemId ?? ''),
    enabled: !!tenantId && !!itemId,
    queryFn: () => getTenantContentItem(tenantId!, itemId!),
    staleTime: 10_000,
  })
}

export function useTenantContentUsage(tenantId: string | null | undefined) {
  return useQuery({
    queryKey: tenantContentKeys.usage(tenantId ?? ''),
    enabled: !!tenantId,
    queryFn: () => getTenantContentUsage(tenantId!),
    staleTime: 30_000,
  })
}

export function useTenantContentReach(
  tenantId: string | null | undefined,
  itemId: string | null | undefined,
  enabled = false,
) {
  return useQuery({
    queryKey: tenantContentKeys.reach(tenantId ?? '', itemId ?? ''),
    enabled: !!tenantId && !!itemId && enabled,
    queryFn: () => previewTenantContentReach(tenantId!, itemId!),
    staleTime: 0,
  })
}

export function usePublicSitesList(tenantId: string | null | undefined) {
  return useQuery({
    queryKey: ['public-sites-list', tenantId ?? ''],
    enabled: !!tenantId,
    queryFn: () => listPublicSitesForTenant(tenantId!),
    staleTime: 60_000,
  })
}
