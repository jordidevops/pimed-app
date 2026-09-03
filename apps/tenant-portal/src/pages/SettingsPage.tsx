import { useTranslation } from 'react-i18next'
import { Outlet, Navigate, useLocation } from 'react-router-dom'
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

  return (
    <div className="w-full max-w-6xl xl:max-w-7xl mx-auto px-4 lg:px-6 py-8">
      <div className="mb-6">
        <h1 className="text-2xl font-bold">
          {t('nav.settings', 'Configuració')}
        </h1>
        {activeTenant && (
          <p className="text-sm text-muted-foreground mt-1">{activeTenant.name}</p>
        )}
      </div>

      {tenantsLoading && (
        <div className="rounded-2xl border p-6 animate-pulse space-y-3">
          <div className="h-4 bg-muted rounded w-1/3" />
          <div className="h-4 bg-muted rounded w-1/2" />
        </div>
      )}

      {!tenantsLoading && !activeTenant && tenants.length > 1 && (
        <div className="bg-amber-50 border border-amber-200 rounded-2xl p-6 text-center">
          <p className="text-sm text-amber-800 font-medium">
            {t('settings.no_tenant_selected', 'Selecciona una organització a la barra lateral per veure la configuració.')}
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
        <div className="flex flex-col lg:flex-row gap-6 lg:gap-8">
          <aside className="lg:w-56 shrink-0">
            <SettingsNav
              activeRole={activeRole}
              canViewOperations={canViewOperations}
              unresolvedCount={unresolvedCount}
              features={features}
            />
          </aside>
          <div className="flex-1 min-w-0">
            <Outlet />
          </div>
        </div>
      )}
    </div>
  )
}
