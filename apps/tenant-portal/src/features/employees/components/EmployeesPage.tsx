import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router-dom'
import { Users } from 'lucide-react'
import { PageShell } from '@/components/layout/PageShell'
import { UnderlineTabs } from '@/components/layout/UnderlineTabs'
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
      <PageShell
        title={t('employees.title', 'Empleats')}
        icon={<Users className="h-5 w-5" aria-hidden />}
      >
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-6 text-center">
          <p className="text-sm font-medium text-amber-800">
            {t('employees.errors.no_tenant', 'Selecciona una organització per veure els empleats')}
          </p>
        </div>
      </PageShell>
    )
  }

  return (
    <PageShell
      title={<span data-testid="employees-page-title">{t('employees.title', 'Empleats')}</span>}
      subtitle={subtitle}
      icon={<Users className="h-5 w-5" aria-hidden />}
      tabs={
        <UnderlineTabs
          activeKey={activeTab}
          aria-label={t('employees.tabs_label', "Seccions d'empleats")}
          items={[
            {
              key: 'list',
              label: t('employees.tabs.list', 'Empleats'),
              onSelect: () => selectTab('list'),
            },
            ...(canManagePortal
              ? [
                  {
                    key: 'portal_hub',
                    label: t('employees.tabs.portal_hub', 'Accés al portal'),
                    onSelect: () => selectTab('portal_hub'),
                  },
                ]
              : []),
            ...(canViewCompliance
              ? [
                  {
                    key: 'compliance',
                    label: t('employees.tabs.compliance', 'Compliment'),
                    onSelect: () => selectTab('compliance'),
                  },
                ]
              : []),
            ...(canManageAssets
              ? [
                  {
                    key: 'assets',
                    label: t('employees.tabs.assets', 'Equipament'),
                    onSelect: () => selectTab('assets'),
                  },
                ]
              : []),
          ]}
        />
      }
    >
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
    </PageShell>
  )
}
