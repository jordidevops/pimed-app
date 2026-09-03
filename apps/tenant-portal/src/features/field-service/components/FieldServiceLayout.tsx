import { NavLink, Navigate, Outlet, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { CalendarDays, ClipboardList, LayoutGrid, Sun } from 'lucide-react'
import { cn } from '@/lib/utils'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { useTenant } from '@/contexts/TenantContext'
import { usePendingChecklistDrain } from '../hooks/usePendingChecklistDrain'
import { useFieldDeviceSync } from '../hooks/useFieldDeviceSync'

const NAV_ITEMS = [
  { to: '/field/today', key: 'today', icon: Sun },
  { to: '/field/orders', key: 'orders', icon: ClipboardList },
  { to: '/field/agenda', key: 'agenda', icon: CalendarDays },
  { to: '/field/more', key: 'more', icon: LayoutGrid },
] as const

export function FieldServiceLayout() {
  const { t } = useTranslation('field-service')
  const location = useLocation()
  const { tenantsLoading, activeTenant } = useTenant()
  const isFieldService = useIsFieldService()
  const tenantId = isFieldService ? (activeTenant?.id ?? null) : null
  const sync = useFieldDeviceSync(tenantId)
  usePendingChecklistDrain(tenantId)

  if (tenantsLoading) {
    return (
      <div className="flex h-64 items-center justify-center" aria-busy="true">
        <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary" />
      </div>
    )
  }

  if (!isFieldService) {
    return <Navigate to="/dashboard" replace />
  }

  if (location.pathname === '/field' || location.pathname === '/field/') {
    return <Navigate to="/field/today" replace />
  }

  const badge = sync.pendingTotal + sync.failedTotal

  return (
    <div className="flex min-h-full flex-col">
      <div className="flex-1 pb-[calc(4rem+env(safe-area-inset-bottom))]">
        <Outlet />
      </div>

      <nav
        className="fixed inset-x-0 bottom-0 z-40 border-t border-border bg-card/95 backdrop-blur supports-[backdrop-filter]:bg-card/80 lg:left-64"
        style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}
        aria-label={t('nav.field', 'Camp')}
      >
        <ul className="mx-auto flex max-w-lg items-stretch justify-around">
          {NAV_ITEMS.map(({ to, key, icon: Icon }) => (
            <li key={key} className="flex-1">
              <NavLink
                to={to}
                className={({ isActive }) =>
                  cn(
                    'relative flex min-h-12 flex-col items-center justify-center gap-0.5 px-2 py-2 text-xs font-medium transition-colors',
                    isActive ? 'text-primary' : 'text-muted-foreground hover:text-foreground',
                  )
                }
              >
                <Icon className="h-5 w-5" aria-hidden />
                {t(`nav.${key}`)}
                {key === 'more' && badge > 0 && (
                  <span className="absolute right-3 top-1.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-destructive px-1 text-[10px] font-bold text-destructive-foreground">
                    {badge > 99 ? '99+' : badge}
                  </span>
                )}
              </NavLink>
            </li>
          ))}
        </ul>
      </nav>
    </div>
  )
}
