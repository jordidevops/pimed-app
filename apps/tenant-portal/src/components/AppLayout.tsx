import { useState } from 'react'
import { NavLink, Navigate, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Users, Package, Building2, MapPin, UserCheck, FileText, ClipboardList, Globe, Clock, CalendarDays, ListChecks, Sparkles, Zap, Briefcase, GitBranch, BarChart3 } from 'lucide-react'
import { useTenant } from '../contexts/TenantContext'
import { UserAvatarMenu } from './UserAvatarMenu'
import { ThemeCustomizer } from './ThemeCustomizer'
import { SiteSelector } from './sidebar/SiteSelector'
import { NotificationBell } from '@/features/notifications/components/NotificationBell'
import { useMyEmployee } from '@/features/attendance/api/useMyEmployee'
import { useTenantFeatures } from '@/features/entity-timeline/api/useTenantFeatures'
import { usePermission } from '@/hooks/usePermission'
import { useIsFieldService, useSectorLabel } from '@/hooks/useSectorLabel'

// ─── Nav items ────────────────────────────────────────────────────────────────

interface NavItem {
  to: string
  label: string
  icon: React.ReactNode
  show?: boolean
  match?: (path: string) => boolean
}

interface NavGroup {
  label?: string
  items: NavItem[]
}

function DashboardIcon() {
  return (
    <svg className="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} aria-hidden>
      <rect x="3" y="3" width="7" height="7" rx="1.5" />
      <rect x="14" y="3" width="7" height="7" rx="1.5" />
      <rect x="3" y="14" width="7" height="7" rx="1.5" />
      <rect x="14" y="14" width="7" height="7" rx="1.5" />
    </svg>
  )
}

function FilesIcon() {
  return (
    <svg className="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M3 7v10a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-6l-2-2H5a2 2 0 0 0-2 2Z" />
    </svg>
  )
}

function SettingsIcon() {
  return (
    <svg className="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 0 0-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 0 0-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 0 0-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 0 0-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 0 0 1.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
      <circle cx="12" cy="12" r="3" />
    </svg>
  )
}

// ─── Tenant selector (inside sidebar) ────────────────────────────────────────

function TenantSelector() {
  const { t } = useTranslation('common')
  const { tenants, selectedTenantId, setSelectedTenantId, activeTenant } = useTenant()
  const navigate = useNavigate()

  if (tenants.length === 0) return null

  // Single tenant — show as a non-interactive badge
  if (tenants.length === 1) {
    return (
      <div className="px-3 py-2 rounded-xl bg-primary/10 border border-primary/20">
        <p className="text-[10px] font-semibold uppercase tracking-widest text-primary/60 mb-0.5">
          {t('tenant', 'Organització')}
        </p>
        <p className="text-sm font-semibold text-primary truncate">
          {tenants[0].name}
        </p>
        <p className="text-[11px] text-primary/70 capitalize mt-0.5">{tenants[0].role}</p>
      </div>
    )
  }

  // Multi-tenant — dropdown
  return (
    <div className="px-3 py-2 rounded-xl bg-primary/10 border border-primary/20">
      <p className="text-[10px] font-semibold uppercase tracking-widest text-primary/60 mb-1.5">
        {t('tenant', 'Organització')}
      </p>
      <select
        value={selectedTenantId ?? ''}
        onChange={(e) => {
          setSelectedTenantId(e.target.value || null)
          // Maps JS loads only once per page (APIProvider first-render only).
          // If Maps JS has been mounted already, force a full reload to avoid
          // using the previous tenant key in the same SPA session.
          const mapsJsLoaded = Boolean((window as any).__mapsJsLoaded)
          if (mapsJsLoaded) {
            window.location.assign('/dashboard')
            return
          }

          // Reset to dashboard when changing tenant so the user doesn't
          // see stale settings from the previous tenant
          navigate('/dashboard')
        }}
        className="w-full text-sm font-medium text-primary bg-transparent border-0 outline-none cursor-pointer focus:ring-0 truncate"
        aria-label={t('select_tenant', 'Selecciona organització')}
      >
        <option value="">{t('all_tenants', 'Totes les organitzacions')}</option>
        {tenants.map((t) => (
          <option key={t.id} value={t.id}>
            {t.name}
          </option>
        ))}
      </select>
      {activeTenant && (
        <p className="text-[11px] text-primary/70 capitalize mt-0.5">{activeTenant.role}</p>
      )}
    </div>
  )
}

// ─── AppLayout ────────────────────────────────────────────────────────────────

/**
 * Shell layout for all authenticated pages.
 * Sidebar (left) + top header + <Outlet /> content area.
 *
 * The tenant selector lives in the sidebar so it's always visible
 * regardless of which page the user is on. Changing the tenant resets
 * the router to /dashboard to avoid stale per-tenant data.
 */
export function AppLayout() {
  const { t } = useTranslation('common')
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const { activeTenant, tenants, tenantsLoading, activeRole } = useTenant()
  const isManager = activeRole === 'owner' || activeRole === 'manager'
  const { data: myEmployee, isLoading: myEmployeeLoading } = useMyEmployee()
  const hasMyEmployee = !myEmployeeLoading && !!myEmployee
  const { data: features } = useTenantFeatures()
  const canViewRecruitment = usePermission('recruitment.view')
  const showRecruitment = Boolean(features?.recruitment_enabled) && canViewRecruitment
  const isFieldService = useIsFieldService()
  const projectLabel = useSectorLabel('project', t('nav.projects', 'Projectes'))
  const contactLabel = useSectorLabel('contact', t('nav.contacts', 'Contactes'))

  // Guard d'onboarding: si el tenant actiu no té sector_profile_id I l'usuari és owner.
  // Els rols no-owner (manager, member, viewer) no poden executar l'RPC apply_sector_recipe
  // (RLS bloqueja UPDATE a data.tenants per a no-owners). En comptes de bloquejar-los
  // amb el wizard, els deixem passar a l'app — el sector es pot configurar més tard.
  if (!tenantsLoading && activeTenant !== null && activeTenant.sector_profile_id === null && activeTenant.role === 'owner') {
    return <Navigate to="/onboarding" replace />
  }

  // Si l'usuari ha triat explícitament "Totes les organitzacions", els mòduls
  // amb scope de tenant no poden renderitzar-se — tornem al dashboard.
  // No redirigir mentre encara s'està resolent el tenant per defecte (race amb
  // l'efecte de TenantContext); això enviava /employees → /dashboard a fred.
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

  const navGroups: NavGroup[] = [
    {
      items: [
        {
          to: isFieldService ? '/field/today' : '/dashboard',
          label: isFieldService ? t('nav.field_today', 'Avui') : t('nav.dashboard', 'Inici'),
          icon: <DashboardIcon />,
          match: isFieldService
            ? (path: string) => path === '/field' || path === '/field/' || path.startsWith('/field/today')
            : undefined,
        },
      ],
    },
    {
      label: t('nav.group_personal', 'Jo'),
      items: [
        { to: '/attendance', label: t('nav.attendance', 'Fitxatge'), icon: <Clock className="h-5 w-5" />, show: hasMyEmployee },
        { to: '/attendance/calendar', label: t('nav.attendance_calendar', 'Calendari'), icon: <CalendarDays className="h-5 w-5" />, show: hasMyEmployee },
        { to: '/ai/chat', label: t('nav.ai_chat', 'Assistent IA'), icon: <Sparkles className="h-5 w-5" /> },
      ],
    },
    {
      label: t('nav.group_team', 'Equip'),
      items: [
        { to: '/employees', label: t('nav.employees', 'Empleats'), icon: <UserCheck className="h-5 w-5" /> },
        { to: '/employees/hr', label: t('nav.hr_reporting', 'Reporting HR'), icon: <BarChart3 className="h-5 w-5" />, show: isManager },
        { to: '/employees/organization', label: t('nav.organization', 'Organigrama'), icon: <GitBranch className="h-5 w-5" /> },
        { to: '/employees/positions', label: t('nav.job_positions', 'Llocs de treball'), icon: <Briefcase className="h-5 w-5" />, show: isManager },
        { to: '/employees/skills', label: t('nav.skills', 'Skills'), icon: <Sparkles className="h-5 w-5" />, show: isManager },
        { to: '/recruitment', label: t('nav.recruitment', 'Reclutament'), icon: <Briefcase className="h-5 w-5" />, show: showRecruitment,
          match: (path: string) => path === '/recruitment' || path.startsWith('/recruitment/'),
        },
        { to: '/attendance-mgmt/dashboard', label: t('nav.control_horari', 'Control horari'), icon: <ListChecks className="h-5 w-5" />, show: isManager },
      ],
    },
    {
      label: t('nav.group_company', 'Empresa'),
      items: [
        { to: '/departments', label: t('nav.departments', 'Departaments'), icon: <Building2 className="h-5 w-5" /> },
        { to: '/locations', label: t('nav.locations', 'Ubicacions'), icon: <MapPin className="h-5 w-5" /> },
        { to: '/catalog', label: t('nav.catalog', 'Catàleg'), icon: <Package className="h-5 w-5" /> },
      ],
    },
    {
      label: t('nav.group_operations', 'Operativa'),
      items: [
        { to: '/contacts', label: contactLabel, icon: <Users className="h-5 w-5" /> },
        // field_service: shell de camp + label sector; la resta d'arquetips: /projects
        { to: '/field/orders', label: projectLabel, icon: <ClipboardList className="h-5 w-5" />, show: isFieldService,
          match: (path: string) => path.startsWith('/field/orders') || path.startsWith('/projects'),
        },
        { to: '/projects', label: projectLabel, icon: <ClipboardList className="h-5 w-5" />, show: !isFieldService },
        { to: '/documents', label: t('nav.documents', 'Documents'), icon: <FileText className="h-5 w-5" /> },
        { to: '/files', label: t('nav.files', 'Fitxers'), icon: <FilesIcon /> },
        { to: '/public-portal', label: t('nav.public_portal', 'Portal Públic'), icon: <Globe className="h-5 w-5" />, show: isManager },
      ],
    },
    {
      label: t('nav.group_automation', 'Automatitzacions'),
      items: [
        { to: '/automation', label: t('nav.automation', 'Centre d\'automatitzacions'), icon: <Zap className="h-5 w-5" />, show: isManager },
      ],
    },
  ]

  const navLinkClass = ({ isActive }: { isActive: boolean }) =>
    `flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium transition-colors select-none ${
      isActive
        ? 'bg-indigo-600 text-white shadow-sm'
        : 'text-muted-foreground hover:bg-accent hover:text-accent-foreground'
    }`
  const location = useLocation()
  const showFieldBottomNav = isFieldService && location.pathname.startsWith('/field')

  const sidebar = (
    <aside className="flex h-full w-64 flex-col border-r border-border bg-card px-4 py-5 gap-5">
      {/* Logo */}
      <div className="flex items-center gap-2.5 px-1">
        <div className="h-7 w-7 rounded-lg bg-indigo-600 flex items-center justify-center shrink-0">
          <svg className="h-4 w-4 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden>
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M3 7h18M3 17h18M6 7v10M18 7v10" />
          </svg>
        </div>
          <span className="font-bold text-foreground">Portal de Clients</span>
      </div>

      {/* Tenant selector */}
      <TenantSelector />

      {/* Site selector (visible only when tenant has sites) */}
      <SiteSelector />

      {/* Navigation */}
      <nav className="flex-1 min-h-0 overflow-y-auto" aria-label={t('nav.main', 'Navegació principal')}>
        <div className="space-y-4">
          {navGroups.map((group, gi) => {
            const visibleItems = group.items.filter(i => i.show !== false)
            if (visibleItems.length === 0) return null
            return (
              <div key={gi}>
                {group.label && (
                  <p className="px-3 mb-1 text-[10px] font-semibold uppercase tracking-widest text-muted-foreground/70">
                    {group.label}
                  </p>
                )}
                <ul className="space-y-0.5">
                  {visibleItems.map((item) => (
                    <li key={item.to}>
                      <NavLink
                        to={item.to}
                        end={Boolean((item as { match?: unknown }).match)}
                        className={({ isActive }) =>
                          navLinkClass({
                            isActive: (item as { match?: (p: string) => boolean }).match
                              ? (item as { match: (p: string) => boolean }).match(location.pathname)
                              : isActive,
                          })
                        }
                        onClick={() => setSidebarOpen(false)}
                      >
                        {item.icon}
                        {item.label}
                      </NavLink>
                    </li>
                  ))}
                </ul>
              </div>
            )
          })}
        </div>
      </nav>

      {/* Bottom: notifications + settings + theme customizer + user avatar */}
      <div className="border-t border-border pt-4 space-y-1">
        <NotificationBell />
        <NavLink
          to="/settings"
          className={navLinkClass}
          onClick={() => setSidebarOpen(false)}
        >
          <SettingsIcon />
          {t('nav.settings', 'Configuració')}
        </NavLink>
        <ThemeCustomizer />
        <UserAvatarMenu menuUp />
      </div>
    </aside>
  )

  return (
    <div className="flex h-full min-h-0 overflow-hidden bg-background">
      {/* Desktop sidebar */}
      <div className="hidden lg:flex lg:shrink-0">
        {sidebar}
      </div>

      {/* Mobile sidebar overlay.
          On /field/* the bottom tab bar is full-width; keep the drawer above it
          so the avatar/settings footer stays visible. */}
      {sidebarOpen && (
        <div
          className={
            showFieldBottomNav
              ? 'fixed inset-x-0 top-0 z-50 flex lg:hidden bottom-[calc(4rem+env(safe-area-inset-bottom))]'
              : 'fixed inset-0 z-40 flex lg:hidden'
          }
        >
          <div
            className="absolute inset-0 bg-black/30"
            onClick={() => setSidebarOpen(false)}
            aria-hidden
          />
          <div className="relative z-10 flex h-full w-64 flex-col">
            {sidebar}
          </div>
        </div>
      )}

      {/* Main content column */}
      <div className="flex flex-1 flex-col min-h-0 min-w-0 overflow-hidden">
        {/* Mobile top bar */}
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
          <span className="font-bold text-foreground">Portal de Clients</span>
          <div className="ml-auto">
            <NotificationBell compact />
          </div>
        </header>

        {/* Page content */}
        <main className="flex-1 min-h-0 overflow-y-auto">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
