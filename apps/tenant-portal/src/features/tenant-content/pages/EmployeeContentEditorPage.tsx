import { Link, useParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useTenant } from '@/contexts/TenantContext'
import { useEmployeePortalEffective } from '@/features/portal-entitlements'
import { useCanManageTenantContent } from '../api/useCanManageTenantContent'
import { ContentEditor } from '../components/ContentEditor'
import { ModuleNotEnabledScreen } from '../components/ModuleNotEnabledScreen'

export function EmployeeContentEditorPage() {
  const { t } = useTranslation('tenant-content')
  const { id } = useParams<{ id: string }>()
  const { activeTenant, tenantScopeReady } = useTenant()
  const tenantId = tenantScopeReady ? activeTenant?.id ?? null : null
  const { effective, isLoading } = useEmployeePortalEffective(tenantId)
  const canManage = useCanManageTenantContent()
  const isNew = !id

  if (!activeTenant || isLoading) {
    return (
      <div className="flex justify-center py-20">
        <div className="animate-spin h-8 w-8 border-b-2 border-primary rounded-full" />
      </div>
    )
  }

  if (effective === false) {
    return <ModuleNotEnabledScreen channel="employee" />
  }

  return (
    <div className="max-w-4xl mx-auto px-4 py-8 space-y-4">
      <Link to="/employees?tab=portal_hub&section=content" className="text-sm text-muted-foreground hover:text-primary">
        ← {t('tenant_content.nav.back_hub', 'Accés al portal')}
      </Link>
      <h1 className="text-2xl font-bold">
        {isNew
          ? t('tenant_content.editor.new_employee', 'Nou contingut (portal empleat)')
          : t('tenant_content.editor.edit', 'Editar contingut')}
      </h1>
      <ContentEditor
        tenantId={activeTenant.id}
        entryContext="employee"
        itemId={id}
        canManage={canManage}
        cancelPath="/employees?tab=portal_hub&section=content"
      />
    </div>
  )
}
