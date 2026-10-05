import { useState } from 'react'
import { Link, NavLink, Navigate, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Building2, MapPin } from 'lucide-react'
import { useTenant } from '../contexts/TenantContext'
import { UserAvatarMenu } from './UserAvatarMenu'
import { ThemeCustomizer } from './ThemeCustomizer'
import { SiteSelector } from './sidebar/SiteSelector'
import { NotificationBell } from '@/features/notifications/components/NotificationBell'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { useSidebarNav, PINNED_MAX_HEIGHT_CLASS, type ResolvedNavItem } from '@/features/sidebar-nav'
import { cn } from '@/lib/utils'
import { FieldBottomNav } from '@/features/field-service/components/FieldBottomNav'
import { useFieldDeviceSync } from '@/features/field-service/hooks/useFieldDeviceSync'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'

function TenantSelector() {
  const { t } = useTranslation('common')
  const { tenants, selectedTenantId, setSelectedTenantId, activeTenant } = useTenant()
  const navigate = useNavigate()

  if (tenants.length === 0) return null

  if (tenants.length === 1) {
    return (
      <div className="px-3 py-2 rounded-xl bg-primary/10 border border-primary/20">
        <p className="text-[10px] font-semibold uppercase tracking-widest text-primary/60 mb-0.5">
          {t('tenant', 'Organització')}
        </p>
        <p className="text-sm font-semibold text-primary truncate">{tenants[0].name}</p>
        <p className="text-[11px] text-primary/70 capitalize mt-0.5">{tenants[0].role}</p>
      </div>
    )
  }

  return (
    <div className="px-3 py-2 rounded-xl bg-primary/10 border border-primary/20">
      <p className="text-[10px] font-semibold uppercase tracking-widest text-primary/60 mb-1.5">
        {t('tenant', 'Organització')}
      </p>
      <select
        value={selectedTenantId ?? ''}
        onChange={(e) => {
          setSelectedTenantId(e.target.value || null)
          const mapsJsLoaded = Boolean((window as any).__mapsJsLoaded)
          if (mapsJsLoaded) {
            window.location.assign('/dashboard')
            return
          }
          navigate('/dashboard')
        }}
        className="w-full text-sm font-medium text-primary bg-transparent border-0 outline-none cursor-pointer focus:ring-0 truncate"
        aria-label={t('select_tenant', 'Selecciona organització')}
      >
        <option value="">{t('all_tenants', 'Totes les organitzacions')}</option>
        {tenants.map((tenant) => (
          <option key={tenant.id} value={tenant.id}>
            {tenant.name}
          </option>
        ))}
      </select>
      {activeTenant && (
        <p className="text-[11px] text-primary/70 capitalize mt-0.5">{activeTenant.role}</p>
      )}
    </div>
  )
}

function SidebarContextSelectors() {
  const { t } = useTranslation('common')
  const { activeTenant, activeSite, sites } = useTenant()
  const tenantLabel = activeTenant?.name ?? t('tenant', 'Organització')
  const siteLabel = activeSite?.name ?? (sites.length > 1 ? t('all_sites', 'Tots els locals') : null)

  return (
    <>
      <div className="hidden [@media(max-height:560px)]:block">
        <Popover>
          <PopoverTrigger asChild>
            <button
              type="button"
              className="flex w-full items-center gap-2 rounded-xl border border-primary/20 bg-primary/10 px-2.5 py-1.5 text-left"
              aria-label={t('nav.context_selector', 'Organització i local')}
            >
              <Building2 className="h-4 w-4 shrink-0 text-primary" aria-hidden />
              <span className="min-w-0 flex-1">
                <span className="block truncate text-xs font-semibold text-primary">{tenantLabel}</span>
                {siteLabel && (
                  <span className="flex items-center gap-1 truncate text-[10px] text-primary/70">
                    <MapPin className="h-3 w-3 shrink-0" aria-hidden />
                    {siteLabel}
                  </span>
                )}
              </span>
            </button>
          </PopoverTrigger>
          <PopoverContent align="start" className="w-64 space-y-3 p-3">
            <TenantSelector />
            <SiteSelector />
          </PopoverContent>
        </Popover>
      </div>
      <div className="space-y-3 [@media(max-height:560px)]:hidden">
        <TenantSelector />
        <SiteSelector />
      </div>
    </>
  )
}

function NavSkeleton() {
  return (
    <div className="space-y-4 animate-pulse" aria-hidden>
      {[1, 2, 3, 4].map((g) => (
        <div key={g} className="space-y-2">
          <div className="mx-3 h-2 w-16 rounded bg-muted" />
          <div className="h-9 rounded-xl bg-muted/70" />
          <div className="h-9 rounded-xl bg-muted/50" />
        </div>
      ))}
    </div>
  )
}

function navItemClassName(opts: {
  isActive: boolean
  emphasis: 'default' | 'accent'
}) {
  if (opts.isActive) return 'tp-nav-item tp-nav-item-active'
  if (opts.emphasis === 'accent') return 'tp-nav-item tp-nav-item-accent'
  return 'tp-nav-item'
}

function SidebarNavItemRow({
  item,
  pathname,
  onNavigate,
  badge,
}: {
  item: ResolvedNavItem
  pathname: string
  onNavigate: () => void
  badge?: number
}) {
  if (item.kind === 'theme') {
    return (
      <ThemeCustomizer
        className={item.emphasis === 'accent' ? 'tp-nav-item-accent' : undefined}
        label={item.label}
        showIcon={item.showIcon}
      />
    )
  }
  if (!item.to) return null
  const Icon = item.icon
  return (
    <NavLink
      to={item.to}
      end={Boolean(item.match)}
      className={({ isActive }) =>
        cn(
          navItemClassName({
            isActive: item.match ? item.match(pathname) : isActive,
            emphasis: item.emphasis,
          }),
          'relative',
        )
      }
      onClick={onNavigate}
    >
      {item.showIcon ? <Icon className="h-5 w-5 shrink-0" /> : <span className="h-5 w-5 shrink-0" aria-hidden />}
      <span className="min-w-0 truncate">{item.label}</span>
      {badge != null && badge > 0 && (
        <span className="ml-auto flex h-4 min-w-4 items-center justify-center rounded-full bg-destructive px-1 text-[10px] font-bold text-destructive-foreground">
          {badge > 99 ? '99+' : badge}
        </span>
      )}
    </NavLink>
  )
}

/**
 * Shell layout for all authenticated pages.
 * Sidebar (left) + top header + <Outlet /> content area.
 */
export function AppLayout() {
  const { t } = useTranslation('common')
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const { activeTenant, tenants, tenantsLoading } = useTenant()
  const isFieldService = useIsFieldService()
  const { resolvedNav, navLoading } = useSidebarNav()
  const location = useLocation()
  const sync = useFieldDeviceSync(activeTenant?.id ?? null, { enableDrain: false })
  const deviceBadge = sync.pendingTotal + sync.failedTotal

  if (!tenantsLoading && activeTenant !== null && activeTenant.sector_profile_id === null && activeTenant.role === 'owner') {
    return <Navigate to="/onboarding" replace />
  }

  const explicitAllTenants =
    !tenantsLoading &&
    tenants.length > 1 &&
    activeTenant === null &&
    typeof sessionStorage !== 'undefined' &&
    sessionStorage.getItem('selectedTenantId') === '__ALL_TENANTS__'

  if (explicitAllTenants) {
    return <Navigate to="/dashboard" replace />
  }

  if (!tenantsLoading && tenants.length > 0 && activeTenant === null) {
    return (
      <div className="flex items-center justify-center h-64" aria-busy="true">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
      </div>
    )
  }

  const navItemIdle = 'tp-nav-item'
  const showFieldBottomNav =
    isFieldService &&
    (location.pathname.startsWith('/field') ||
      location.pathname === '/attendance' ||
      location.pathname.startsWith('/attendance/') ||
      location.pathname === '/dashboard')

  const brandLink = (
    <Link
      to="/app"
      className="flex items-center gap-2.5 px-1 rounded-lg focus:outline-none focus-visible:ring-2 focus-visible:ring-ring [@media(max-height:560px)]:gap-1.5"
      onClick={() => setSidebarOpen(false)}
      aria-label={t('app_index.open_from_logo', 'Índex de l\'aplicació')}
    >
      <div className="h-7 w-7 rounded-lg bg-primary flex items-center justify-center shrink-0">
        <svg className="h-4 w-4 text-primary-foreground" fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden>
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M3 7h18M3 17h18M6 7v10M18 7v10" />
        </svg>
      </div>
      <span className="font-bold text-foreground [@media(max-height:560px)]:text-sm">Portal de Clients</span>
    </Link>
  )

  const sidebar = (
    <aside
      className={cn(
        'flex h-full w-64 flex-col border-r border-border bg-card px-4 py-5 gap-5',
        '[@media(max-height:560px)]:gap-2 [@media(max-height:560px)]:overflow-y-auto [@media(max-height:560px)]:py-2',
      )}
    >
      {brandLink}

      <SidebarContextSelectors />

      <nav
        className={cn(
          'flex min-h-0 flex-1 flex-col gap-3',
          '[@media(max-height:560px)]:min-h-min [@media(max-height:560px)]:flex-none',
        )}
        aria-label={t('nav.main', 'Navegació principal')}
      >
        {navLoading ? (
          <NavSkeleton />
        ) : (
          <>
            {resolvedNav.pinned && (
              <div
                className={cn(
                  'overflow-y-auto border-b border-border pb-3',
                  'shrink-0',
                  PINNED_MAX_HEIGHT_CLASS,
                  // Short height: parent aside scrolls — avoid nested scroll regions.
                  '[@media(max-height:560px)]:max-h-none [@media(max-height:560px)]:shrink [@media(max-height:560px)]:overflow-visible',
                )}
              >
                <ul className="space-y-0.5">
                  {resolvedNav.pinned.items.map((item) => (
                    <li key={item.id}>
                      <SidebarNavItemRow
                        item={item}
                        pathname={location.pathname}
                        onNavigate={() => setSidebarOpen(false)}
                        badge={item.id === 'field_device' ? deviceBadge : undefined}
                      />
                    </li>
                  ))}
                </ul>
              </div>
            )}

            <div className="min-h-0 flex-1 overflow-y-auto [@media(max-height:560px)]:min-h-min [@media(max-height:560px)]:flex-none [@media(max-height:560px)]:overflow-visible">
              <div className="space-y-4 [@media(max-height:560px)]:space-y-2">
                {resolvedNav.groups.map((group) => (
                  <div key={group.id}>
                    {group.label && (
                      <p className="px-3 mb-1 text-[10px] font-semibold uppercase tracking-widest text-muted-foreground/70">
                        {group.label}
                      </p>
                    )}
                    <ul className="space-y-0.5">
                      {group.items.map((item) => (
                        <li key={item.id}>
                          <SidebarNavItemRow
                            item={item}
                            pathname={location.pathname}
                            onNavigate={() => setSidebarOpen(false)}
                            badge={item.id === 'field_device' ? deviceBadge : undefined}
                          />
                        </li>
                      ))}
                    </ul>
                  </div>
                ))}
              </div>
            </div>
          </>
        )}
      </nav>

      <div
        className={cn(
          'border-t border-border pt-4 space-y-1 shrink-0',
          '[@media(max-height:560px)]:flex [@media(max-height:560px)]:items-center [@media(max-height:560px)]:gap-1 [@media(max-height:560px)]:space-y-0 [@media(max-height:560px)]:pt-2',
        )}
      >
        <div className="space-y-1 [@media(max-height:560px)]:hidden">
          <NotificationBell itemClassName={navItemIdle} />
          <UserAvatarMenu menuUp itemClassName={navItemIdle} />
        </div>
        <div className="hidden [@media(max-height:560px)]:contents">
          <NotificationBell compact itemClassName={navItemIdle} />
          <UserAvatarMenu menuUp compact itemClassName={navItemIdle} />
        </div>
      </div>
    </aside>
  )

  return (
    <div className="flex h-full min-h-0 overflow-hidden bg-background">
      <div className="hidden lg:flex lg:shrink-0">{sidebar}</div>

      {sidebarOpen && (
        <div
          className={
            showFieldBottomNav
              ? 'fixed inset-x-0 top-0 z-50 flex lg:hidden bottom-[calc(4rem+env(safe-area-inset-bottom))]'
              : 'fixed inset-0 z-40 flex lg:hidden'
          }
        >
          <div className="absolute inset-0 bg-black/30" onClick={() => setSidebarOpen(false)} aria-hidden />
          <div className="relative z-10 flex h-full w-64 flex-col">{sidebar}</div>
        </div>
      )}

      <div className="flex flex-1 flex-col min-h-0 min-w-0 overflow-hidden">
        <header className="flex items-center gap-3 border-b border-border bg-card px-4 py-3 lg:hidden">
          <button
            type="button"
            onClick={() => setSidebarOpen(true)}
            className="rounded-lg p-1.5 text-muted-foreground hover:bg-accent"
            aria-label={t('nav.open_menu', 'Obre el menú')}
          >
            <svg className="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} aria-hidden>
              <path strokeLinecap="round" strokeLinejoin="round" d="M4 6h16M4 12h16M4 18h16" />
            </svg>
          </button>
          <Link to="/app" className="font-bold text-foreground" onClick={() => setSidebarOpen(false)}>
            Portal de Clients
          </Link>
          <div className="ml-auto">
            <NotificationBell compact />
          </div>
        </header>

        <main
          className={cn(
            'flex-1 min-h-0 overflow-y-auto',
            showFieldBottomNav && 'pb-[calc(4rem+env(safe-area-inset-bottom))] lg:pb-0',
          )}
        >
          <Outlet />
        </main>
      </div>
      {showFieldBottomNav && <FieldBottomNav />}
    </div>
  )
}
