import { useMutation, useQueryClient } from '@tanstack/react-query'
import {
  archiveTenantContentItem,
  publishTenantContentItem,
  upsertTenantContentItem,
} from './tenantContentService'
import { tenantContentKeys } from './tenantContentKeys'
import { revalidatePublicPortalPaths } from '../utils/revalidatePortal'
import type { PublishContentResult, UpsertContentResult } from './tenantContentTypes'

export function useUpsertTenantContentItem(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (payload: Record<string, unknown>) => upsertTenantContentItem(tenantId, payload),
    onSuccess: (result: UpsertContentResult) => {
      if (result.ok) {
        qc.invalidateQueries({ queryKey: tenantContentKeys.all(tenantId) })
      }
    },
  })
}

export function usePublishTenantContentItem(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (args: {
      itemId: string
      siteSlug?: string
      locales?: string[]
      pageSlug?: string
    }) => {
      const result = await publishTenantContentItem(tenantId, args.itemId)
      if (!result.ok) return result

      if (args.siteSlug && args.pageSlug && args.locales?.length) {
        try {
          await revalidatePublicPortalPaths({
            siteSlug: args.siteSlug,
            pageSlug: args.pageSlug,
            locales: args.locales,
          })
        } catch (err) {
          console.warn('[tenant-content] revalidate after publish failed', err)
        }
      }

      return result as PublishContentResult
    },
    onSuccess: (result) => {
      if (result.ok) {
        qc.invalidateQueries({ queryKey: tenantContentKeys.all(tenantId) })
        qc.invalidateQueries({ queryKey: ['portal-entitlements', tenantId] })
      }
    },
  })
}

export function useArchiveTenantContentItem(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (itemId: string) => archiveTenantContentItem(tenantId, itemId),
    onSuccess: (result) => {
      if (result.ok) {
        qc.invalidateQueries({ queryKey: tenantContentKeys.all(tenantId) })
      }
    },
  })
}

export function mapContentErrorCode(code: string, t: (key: string, fb: string) => string): string {
  const map: Record<string, string> = {
    cms_tier_insufficient: t('tenant_content.errors.cms_tier_insufficient', 'El teu pla no permet aquesta funció.'),
    last_channel_required: t('tenant_content.errors.last_channel_required', 'Cal mantenir almenys un canal actiu.'),
    public_site_required: t('tenant_content.errors.public_site_required', 'Selecciona un lloc web públic.'),
    quota_pages_exceeded: t('tenant_content.errors.quota_pages_exceeded', 'Has assolit el màxim de pàgines per site.'),
    module_not_included: t('tenant_content.errors.module_not_included', 'El pla no inclou aquest mòdul.'),
    module_not_enabled: t('tenant_content.errors.module_not_enabled', 'El mòdul no està activat.'),
  }
  return map[code] ?? t('tenant_content.errors.generic', 'No s\'ha pogut desar el contingut.')
}
