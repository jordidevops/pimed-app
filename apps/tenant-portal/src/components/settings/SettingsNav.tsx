import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { NavLink, useLocation, useNavigate } from 'react-router-dom'
import { cn } from '@/lib/utils'
import { usePermission } from '@/hooks/usePermission'
import type { TenantTimelineFeatures } from '@/features/entity-timeline/api/tenantFeaturesService'
import {
  buildSettingsNavItems,
  groupSettingsNavItems,
  isSettingsNavItemActive,
} from './settingsNavConfig'

interface SettingsNavProps {
  activeRole: string | null
  canViewOperations: boolean
  unresolvedCount: number
  features?: TenantTimelineFeatures
  className?: string
}

export function SettingsNav({
  activeRole,
  canViewOperations,
  unresolvedCount,
  features,
  className,
}: SettingsNavProps) {
  const { t } = useTranslation(['settings'])
  const { pathname } = useLocation()
  const navigate = useNavigate()

  const isOwner = activeRole === 'owner'
  const isManagerOrOwner = activeRole === 'owner' || activeRole === 'manager'
  const canManageSettings = usePermission('settings.manage', null)

  const items = useMemo(
    () =>
      buildSettingsNavItems({
        isOwner,
        isManagerOrOwner,
        canManageSettings,
        canViewOperations,
        unresolvedCount,
        features,
      }),
    [isOwner, isManagerOrOwner, canManageSettings, canViewOperations, unresolvedCount, features],
  )

  const groups = useMemo(() => groupSettingsNavItems(items), [items])

  const activeItem =
    items.find((item) => isSettingsNavItemActive(pathname, item)) ?? items[0]

  if (items.length <= 1) return null

  return (
    <div className={className}>
      {/* Mobile: jump to section */}
      <div className="lg:hidden mb-4">
        <label className="sr-only" htmlFor="settings-nav-mobile">
          {t('nav.mobile_label', 'Secció de configuració')}
        </label>
        <select
          id="settings-nav-mobile"
          value={activeItem?.to ?? ''}
          onChange={(e) => navigate(e.target.value)}
          className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
        >
          {items.map((item) => (
            <option key={item.to} value={item.to}>
              {t(item.labelKey, item.labelDefault)}
            </option>
          ))}
        </select>
      </div>

      {/* Desktop: vertical nav */}
      <nav
        className="hidden lg:block space-y-6"
        aria-label={t('nav.aria', 'Seccions de configuració')}
      >
        {groups.map(({ group, label, items: groupItems }) => (
          <div key={group}>
            <p className="px-3 mb-1.5 text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
              {t(label.key, label.default)}
            </p>
            <ul className="space-y-0.5">
              {groupItems.map((item) => {
                const Icon = item.icon
                const active = isSettingsNavItemActive(pathname, item)
                return (
                  <li key={item.to}>
                    <NavLink
                      to={item.to}
                      className={cn(
                        'flex items-center gap-2.5 rounded-md px-3 py-2 text-sm font-medium transition-colors border-l-2',
                        active
                          ? 'border-primary bg-accent text-accent-foreground'
                          : 'border-transparent text-muted-foreground hover:bg-accent/50 hover:text-foreground',
                      )}
                    >
                      <Icon className="h-4 w-4 shrink-0" aria-hidden />
                      <span className="truncate flex-1">{t(item.labelKey, item.labelDefault)}</span>
                      {item.badge != null && item.badge > 0 && (
                        <span className="inline-flex min-w-[1.25rem] items-center justify-center rounded-full bg-destructive px-1.5 py-0.5 text-[10px] font-semibold leading-none text-destructive-foreground">
                          {item.badge > 99 ? '99+' : item.badge}
                        </span>
                      )}
                    </NavLink>
                  </li>
                )
              })}
            </ul>
          </div>
        ))}
      </nav>
    </div>
  )
}
