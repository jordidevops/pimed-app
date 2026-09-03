import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router-dom'
import { Users } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { usePermission } from '@/hooks/usePermission'
import { useCanManageEmployeePortal } from '@/features/employee-portal/api/useCanManageEmployeePortal'
import { useEmployeePortalEffective, EmployeePortalActivation } from '@/features/portal-entitlements'
import { useEmployees } from '../api/useEmployees'
import { useEmployeePermissions } from '../hooks/useEmployeePermissions'
import { EmployeesListTab } from './EmployeesListTab'
import { EmployeesPortalHubTab } from './EmployeesPortalHubTab'
import { EmployeesComplianceCatalogTab } from './EmployeesComplianceCatalogTab'
import { EmployeesAssetTypesTab } from './EmployeesAssetTypesTab'
import { ScrollableTabBar } from '@/components/ui/scrollable-tab-bar'

type EmployeesPageTab = 'list' | 'portal_hub' | 'compliance' | 'assets'

export function EmployeesPage() {
  const { t } = useTranslation('employees')
  const { activeTenant, tenants, tenantsLoading, selectedSiteId } = useTenant()
  const [searchParams, setSearchParams] = useSearchParams()
  const [portalEmployeeCount, setPortalEmployeeCount] = useState<number | null>(null)

  const { data: allEmployees = [], isLoading } = useEmployees()

  const activeTab: EmployeesPageTab =
    searchParams.get('tab') === 'portal_hub'
      ? 'portal_hub'
      : searchParams.get('tab') === 'compliance'
        ? 'compliance'
        : searchParams.get('tab') === 'assets'
          ? 'assets'
          : 'list'

  const canWrite = useEmployeePermissions().canManage
  const canManageCompliance = usePermission('compliance.requirements.manage', null)
  const canViewCertifications = usePermission('compliance.certifications.view', null)
  const canViewCompliance = canManageCompliance || canViewCertifications
  const canManageAssets = usePermission('assets.manage', null)
  const canManagePortal = useCanManageEmployeePortal()
  const scopedTenantId = activeTenant?.id ?? null
  const { effective: employeePortalEffective, isLoading: portalEntitlementsLoading } =
    useEmployeePortalEffective(scopedTenantId)

  const visibleEmployeeCount = useMemo(() => {
    if (!selectedSiteId) return allEmployees.length
    return allEmployees.filter((e) => e.site_id === selectedSiteId).length
  }, [allEmployees, selectedSiteId])

  const subtitle = useMemo(() => {
    if (activeTab === 'portal_hub' && portalEmployeeCount != null) {
      return t('employees.portal_hub.subtitle_count', '{{count}} empleats actius al hub', {
        count: portalEmployeeCount,
      })
    }
    return t('employees.subtitle', '{{count}} empleats', { count: visibleEmployeeCount })
  }, [activeTab, visibleEmployeeCount, portalEmployeeCount, t])

  function selectTab(tab: EmployeesPageTab) {
    const next = new URLSearchParams(searchParams)
    if (tab === 'list') next.delete('tab')
    else next.set('tab', tab)
    setSearchParams(next, { replace: true })
  }

  if (tenantsLoading || isLoading || (activeTab === 'portal_hub' && portalEntitlementsLoading)) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
      </div>
    )
  }

  if (!activeTenant && tenants.length > 1) {
    return (
      <div className="max-w-3xl mx-auto px-4 py-10">
        <div className="bg-amber-50 border border-amber-200 rounded-2xl p-6 text-center">
          <p className="text-sm text-amber-800 font-medium">
            {t('employees.errors.no_tenant', 'Selecciona una organització per veure els empleats')}
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-7xl space-y-6 px-4 py-8">
      <div className="flex flex-wrap items-center gap-3 min-w-0">
        <div className="h-10 w-10 rounded-xl bg-primary/10 flex items-center justify-center shrink-0">
          <Users className="h-5 w-5 text-primary" aria-hidden />
        </div>
        <div className="min-w-0">
          <h1 className="text-xl font-bold text-foreground" data-testid="employees-page-title">
            {t('employees.title', 'Empleats')}
          </h1>
          <p className="text-sm text-muted-foreground">{subtitle}</p>
        </div>
      </div>

      <ScrollableTabBar
        activeKey={activeTab}
        aria-label={t('employees.tabs_label', "Seccions d'empleats")}
        className="border-b mb-4"
      >
        <button
          type="button"
          data-tab-key="list"
          onClick={() => selectTab('list')}
          className={`px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors whitespace-nowrap ${
            activeTab === 'list'
              ? 'border-primary text-primary'
              : 'border-transparent text-muted-foreground hover:text-foreground'
          }`}
        >
          {t('employees.tabs.list', 'Empleats')}
        </button>
        {canManagePortal ? (
          <button
            type="button"
            data-tab-key="portal_hub"
            onClick={() => selectTab('portal_hub')}
            className={`px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors whitespace-nowrap ${
              activeTab === 'portal_hub'
                ? 'border-primary text-primary'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            {t('employees.tabs.portal_hub', 'Accés al portal')}
          </button>
        ) : null}
        {canViewCompliance ? (
          <button
            type="button"
            data-tab-key="compliance"
            onClick={() => selectTab('compliance')}
            className={`px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors whitespace-nowrap ${
              activeTab === 'compliance'
                ? 'border-primary text-primary'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            {t('employees.tabs.compliance', 'Compliment')}
          </button>
        ) : null}
        {canManageAssets ? (
          <button
            type="button"
            data-tab-key="assets"
            onClick={() => selectTab('assets')}
            className={`px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors whitespace-nowrap ${
              activeTab === 'assets'
                ? 'border-primary text-primary'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            {t('employees.tabs.assets', 'Equipament')}
          </button>
        ) : null}
      </ScrollableTabBar>

      {activeTab === 'portal_hub' && canManagePortal ? (
        employeePortalEffective === false ? (
          <EmployeePortalActivation />
        ) : (
          <EmployeesPortalHubTab onSubtitleChange={setPortalEmployeeCount} />
        )
      ) : activeTab === 'compliance' && canViewCompliance ? (
        <EmployeesComplianceCatalogTab />
      ) : activeTab === 'assets' && canManageAssets ? (
        <EmployeesAssetTypesTab />
      ) : (
        <EmployeesListTab canWrite={canWrite} />
      )}
    </div>
  )
}
