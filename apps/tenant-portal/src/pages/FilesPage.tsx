import { useTranslation } from 'react-i18next'
import { useTenant } from '../contexts/TenantContext'
import { FileExplorer } from '../features/storage'

export function FilesPage() {
  const { t } = useTranslation('storage')
  const { activeTenant, tenants, tenantsLoading } = useTenant()

  if (tenantsLoading) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600" />
      </div>
    )
  }

  if (!activeTenant && tenants.length > 1) {
    return (
      <div className="max-w-3xl mx-auto px-4 py-10">
        <div className="bg-amber-50 border border-amber-200 rounded-2xl p-6 text-center">
          <p className="text-sm text-amber-800 font-medium">
            {t('storage.explorer.select_tenant_hint', 'Selecciona una organització a la barra lateral per veure els fitxers.')}
          </p>
        </div>
      </div>
    )
  }

  if (!activeTenant) return null

  return (
    <div className="h-full p-4">
      <FileExplorer tenantId={activeTenant.id} />
    </div>
  )
}
