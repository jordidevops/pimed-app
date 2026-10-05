import { useTranslation } from 'react-i18next'
import { Outlet, Navigate, useLocation } from 'react-router-dom'
import { Settings } from 'lucide-react'
import { PageShell } from '@/components/layout/PageShell'
import { useTenant } from '../contexts/TenantContext'
import { useUnresolvedOperationCount } from '../hooks/useUnresolvedOperationCount'
import { useTenantFeatures } from '../features/entity-timeline/api/useTenantFeatures'
import { SettingsNav } from '../components/settings/SettingsNav'

/**
 * SettingsPage — layout shell amb navegació vertical.
 */
export function SettingsPage() {
  const { t } = useTranslation(['common', 'settings'])
  const { activeTenant, activeRole, tenants, tenantsLoading } = useTenant()
  const { pathname } = useLocation()

  const { data: features } = useTenantFeatures()

  const canViewOperations = activeRole === 'owner' || activeRole === 'manager'
  const { data: unresolvedCount = 0 } = useUnresolvedOperationCount(
    activeTenant?.id,
    canViewOperations,
  )

  if (pathname === '/settings' || pathname === '/settings/') {
    return <Navigate to="/settings/config" replace />
  }

  const subtitle = pathname.startsWith('/settings/config')
    ? t(
        'settings:settings.config.page_description',
        "Paràmetres generals de l'organització heretats per tots els membres i locals.",
      )
    : (activeTenant?.name ?? undefined)

  return (
    <PageShell
      title={t('nav.settings', 'Configuració')}
      subtitle={subtitle}
      icon={<Settings className="h-5 w-5" aria-hidden />}
    >
      {tenantsLoading && (
        <div className="animate-pulse space-y-3 rounded-2xl border p-6">
          <div className="h-4 w-1/3 rounded bg-muted" />
          <div className="h-4 w-1/2 rounded bg-muted" />
        </div>
      )}

      {!tenantsLoading && !activeTenant && tenants.length > 1 && (
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-6 text-center">
          <p className="text-sm font-medium text-amber-800">
            {t(
              'settings.no_tenant_selected',
              'Selecciona una organització a la barra lateral per veure la configuració.',
            )}
          </p>
        </div>
      )}

      {!tenantsLoading && tenants.length === 0 && (
        <div className="rounded-2xl border p-6 text-center">
          <p className="text-sm text-muted-foreground">
            {t('settings.no_tenants', 'No pertanys a cap organització.')}
          </p>
        </div>
      )}

      {activeTenant && (
        <div className="flex flex-col gap-6 lg:flex-row lg:gap-8">
          <aside className="shrink-0 lg:w-56">
            <SettingsNav
              activeRole={activeRole}
              canViewOperations={canViewOperations}
              unresolvedCount={unresolvedCount}
              features={features}
            />
          </aside>
          <div className="min-w-0 flex-1">
            <Outlet />
          </div>
        </div>
      )}
    </PageShell>
  )
}
