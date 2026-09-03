import { useTranslation } from 'react-i18next'
import { usePortalEntitlements } from '@/features/portal-entitlements'
import { useTenantContentUsage } from '../api/useTenantContentItems'
import { pagesUsedForSite, isAdvancedEmployeeTier, isAdvancedPublicTier } from '../utils/tierGuards'

interface Props {
  tenantId: string
  channel: 'employee' | 'public'
  publicSiteId?: string | null
}

export function PortalModuleUsageCard({ tenantId, channel, publicSiteId }: Props) {
  const { t } = useTranslation('tenant-content')
  const { data: entitlements } = usePortalEntitlements(tenantId)
  const { data: usageData } = useTenantContentUsage(tenantId)

  if (!entitlements) return null

  const ch = channel === 'employee' ? entitlements.employee_portal : entitlements.public_portal
  const maxPages = ch.max_pages ?? 0
  const used = publicSiteId ? pagesUsedForSite(entitlements, publicSiteId) : 0
  const empAdv = isAdvancedEmployeeTier(entitlements)
  const pubAdv = isAdvancedPublicTier(entitlements)

  return (
    <div className="rounded-xl border bg-muted/30 p-4 space-y-3 text-sm">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="font-medium text-foreground">
          {t('tenant_content.usage.title', 'Pla i capacitats CMS')}
        </p>
        <span className="text-xs px-2 py-0.5 rounded-full bg-primary/10 text-primary font-medium">
          {t('tenant_content.usage.tier', 'Tier')}: {ch.cms_tier}
        </span>
      </div>

      {channel === 'public' && publicSiteId && maxPages > 0 && (
        <div>
          <div className="flex justify-between text-xs text-muted-foreground mb-1">
            <span>{t('tenant_content.usage.pages_per_site', 'Pàgines / site')}</span>
            <span>{used} / {maxPages}</span>
          </div>
          <div className="h-2 rounded-full bg-muted overflow-hidden">
            <div
              className="h-full bg-primary transition-all"
              style={{ width: `${Math.min(100, (used / maxPages) * 100)}%` }}
            />
          </div>
        </div>
      )}

      {usageData?.usage && (
        <p className="text-xs text-muted-foreground">
          {t('tenant_content.usage.items_total', '{{count}} items actius', {
            count: usageData.usage.content_items_total,
          })}
        </p>
      )}

      <ul className="text-xs space-y-1 text-muted-foreground">
        <li>
          {empAdv ? '✓' : '✗'} {t('tenant_content.usage.sticky_dept', 'Sticky / dept / programació (empleat)')}
          {!empAdv && channel === 'employee' ? (
            <span className="text-amber-700 dark:text-amber-400">
              {' '}
              — {t('tenant_content.tier_hint.requires_advanced', 'requereix advanced')}
            </span>
          ) : null}
        </li>
        <li>
          {pubAdv ? '✓' : '✗'} {t('tenant_content.usage.web_translations', 'Traduccions web / lead form')}
          {!pubAdv && channel === 'public' ? (
            <span className="text-amber-700 dark:text-amber-400">
              {' '}
              — {t('tenant_content.tier_hint.requires_advanced', 'requereix advanced')}
            </span>
          ) : null}
        </li>
      </ul>
    </div>
  )
}
