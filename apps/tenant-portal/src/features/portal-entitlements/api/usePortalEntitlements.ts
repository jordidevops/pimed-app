import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'

export type PortalChannelEntitlements = {
  included_by_plan: boolean
  enabled_by_tenant: boolean
  effective: boolean
  cms_tier: string
  max_pages?: number
  pages_used_by_site?: Record<string, number>
}

/** Canal customer_portal (resolve / my_portal_entitlements). */
export type CustomerPortalChannelEntitlements = {
  effective: boolean
  enabled_by_tenant: boolean
  enabled_by_platform: boolean
  can_create_shares: boolean
  can_grant_portal_access: boolean
  mode_effective?: string
  included_granted?: boolean
  included_plan?: boolean
  mode_granted?: string
  mode_plan?: string
  platform_max_mode?: string
  new_share_policy?: string
  new_access_policy?: string
  existing_access_policy?: string
  restriction_reason?: string | null
  restriction_note?: string | null
  bulletin_bcc_emails?: string[] | null
  supported_locales?: string[] | null
  default_locale?: string | null
  allow_client_locale_change?: boolean | null
}

export type ResolvedPortalEntitlements = {
  tenant_id: string
  employee_portal: PortalChannelEntitlements
  public_portal: PortalChannelEntitlements
  customer_portal?: CustomerPortalChannelEntitlements
}

const STALE_MS = 60_000

/**
 * Entitlements resolts (pla + flags tenant + overrides) via api.my_portal_entitlements.
 */
export function usePortalEntitlements(tenantId: string | null | undefined) {
  return useQuery<ResolvedPortalEntitlements | null>({
    queryKey: ['portal-entitlements', tenantId ?? ''],
    enabled: !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('my_portal_entitlements')
        .select('entitlements')
        .maybeSingle()

      if (error) throw error
      return (data?.entitlements as ResolvedPortalEntitlements | null) ?? null
    },
    staleTime: STALE_MS,
  })
}

export function useEmployeePortalEffective(tenantId: string | null | undefined) {
  const q = usePortalEntitlements(tenantId)
  return {
    ...q,
    effective: q.data?.employee_portal?.effective ?? null,
    cmsTier: q.data?.employee_portal?.cms_tier ?? null,
  }
}

export function usePublicPortalEffective(tenantId: string | null | undefined) {
  const q = usePortalEntitlements(tenantId)
  return {
    ...q,
    effective: q.data?.public_portal?.effective ?? null,
    cmsTier: q.data?.public_portal?.cms_tier ?? null,
    maxPages: q.data?.public_portal?.max_pages ?? null,
    pagesUsedBySite: q.data?.public_portal?.pages_used_by_site ?? {},
  }
}

export function useCustomerPortalEffective(tenantId: string | null | undefined) {
  const q = usePortalEntitlements(tenantId)
  const cp = q.data?.customer_portal
  return {
    ...q,
    effective: cp?.effective ?? null,
    enabledByTenant: cp?.enabled_by_tenant ?? null,
    enabledByPlatform: cp?.enabled_by_platform ?? null,
    canCreateShares: cp?.can_create_shares ?? null,
    canGrantPortalAccess: cp?.can_grant_portal_access ?? null,
    modeEffective: cp?.mode_effective ?? null,
    bulletinBccEmails: Array.isArray(cp?.bulletin_bcc_emails)
      ? cp!.bulletin_bcc_emails!
      : [],
    supportedLocales: Array.isArray(cp?.supported_locales)
      ? (cp!.supported_locales as string[])
      : ['ca', 'es', 'en'],
    defaultLocale: cp?.default_locale ?? 'es',
    allowClientLocaleChange: cp?.allow_client_locale_change === true,
    customerPortal: cp ?? null,
  }
}
