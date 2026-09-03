import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { NavLink, Navigate, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { FileText, ListTree, ShieldAlert } from 'lucide-react'
import { cn } from '@/lib/utils'
import { useTenant } from '../../contexts/TenantContext'
import { useTenantFeatures } from '../../features/entity-timeline/api/useTenantFeatures'
import { TimelineFeatureDisabledNotice } from '../../features/entity-timeline/components/TimelineFeatureDisabledNotice'

interface ActivitySubNavItem {
  to: string
  segment: string
  labelKey: string
  labelDefault: string
  icon: typeof ShieldAlert
  show: boolean
}

function ActivitySettingsIndex({ items }: { items: ActivitySubNavItem[] }) {
  const first = items.find((i) => i.show)
  if (!first) return null
  return <Navigate to={first.segment} replace />
}

export function ActivitySettingsLayout() {
  const { t } = useTranslation('settings')
  const { activeRole, activeTenant } = useTenant()
  const { pathname } = useLocation()
  const navigate = useNavigate()
  const { data: features, isLoading: featuresLoading } = useTenantFeatures()

  const canManage = activeRole === 'owner' || activeRole === 'manager'

  const subItems = useMemo<ActivitySubNavItem[]>(
    () => [
      {
        to: '/settings/activity/risk',
        segment: 'risk',
        labelKey: 'activity.nav.risk',
        labelDefault: 'Detector de risc',
        icon: ShieldAlert,
        show: features?.entity_timeline_risk_detector !== false,
      },
      {
        to: '/settings/activity/protocols',
        segment: 'protocols',
        labelKey: 'activity.nav.protocols',
        labelDefault: 'Protocols automàtics',
        icon: ListTree,
        show: features?.entity_timeline_playbooks !== false,
      },
      {
        to: '/settings/activity/templates',
        segment: 'templates',
        labelKey: 'activity.nav.templates',
        labelDefault: 'Plantilles de comentaris',
        icon: FileText,
        show: true,
      },
    ],
    [features],
  )

  const visibleItems = subItems.filter((i) => i.show)
  const isIndex = pathname === '/settings/activity' || pathname === '/settings/activity/'
  const activeItem = visibleItems.find((i) => pathname === i.to) ?? visibleItems[0]

  if (!canManage) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('activity.forbidden', 'Només owner/manager pot gestionar les activitats.')}
      </p>
    )
  }

  if (!featuresLoading && visibleItems.length === 0) {
    return (
      <TimelineFeatureDisabledNotice
        titleKey="activity.feature_disabled_title"
        titleDefault="Activitats no disponibles"
        descriptionKey="activity.feature_disabled_description"
        descriptionDefault="Aquesta funcionalitat no està inclosa al pla de la teva organització."
      />
    )
  }

  if (isIndex) {
    return <ActivitySettingsIndex items={subItems} />
  }

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-foreground">
          {t('tabs.activity', 'Activitats')}
        </h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          {t(
            'activity.description',
            'Configura alertes, automatitzacions i plantilles de la timeline d\'entitats.',
          )}
        </p>
      </div>

      {visibleItems.length > 1 && (
        <div className="lg:hidden">
          <label className="sr-only" htmlFor="activity-subnav-mobile">
            {t('activity.nav.mobile', 'Subsecció')}
          </label>
          <select
            id="activity-subnav-mobile"
            className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            value={activeItem?.to ?? ''}
            onChange={(e) => navigate(e.target.value)}
          >
            {visibleItems.map((item) => (
              <option key={item.to} value={item.to}>
                {t(item.labelKey, item.labelDefault)}
              </option>
            ))}
          </select>
        </div>
      )}

      <div className={cn(visibleItems.length > 1 && 'lg:flex lg:gap-8')}>
        {visibleItems.length > 1 && (
          <nav
            className="hidden lg:flex flex-col w-48 shrink-0 border-r border-border pr-4 space-y-0.5"
            aria-label={t('activity.nav.aria', 'Activitats')}
          >
            {visibleItems.map((item) => {
              const Icon = item.icon
              const active = pathname === item.to
              return (
                <NavLink
                  key={item.to}
                  to={item.to}
                  className={cn(
                    'flex items-center gap-2 rounded-md px-2.5 py-2 text-sm font-medium transition-colors border-l-2',
                    active
                      ? 'border-primary bg-accent text-accent-foreground'
                      : 'border-transparent text-muted-foreground hover:bg-accent/50 hover:text-foreground',
                  )}
                >
                  <Icon className="h-4 w-4 shrink-0" aria-hidden />
                  {t(item.labelKey, item.labelDefault)}
                </NavLink>
              )
            })}
          </nav>
        )}
        <div className="flex-1 min-w-0">
          <Outlet />
        </div>
      </div>
    </div>
  )
}
