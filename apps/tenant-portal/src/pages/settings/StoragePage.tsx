import { useTranslation } from 'react-i18next'
import { useTenant } from '../../contexts/TenantContext'
import { ByosConfigForm } from '../../features/storage'

export function StoragePage() {
  const { t } = useTranslation(['settings', 'storage'])
  const { activeTenant, activeRole } = useTenant()

  if (!activeTenant || !activeRole) return null

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-foreground">
          {t('settings:tabs.storage', 'Emmagatzematge')}
        </h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          {t('settings:storage.page_description', "Connecta el teu propi proveïdor de núvol i gestiona les unitats d'emmagatzematge.")}
        </p>
      </div>
      <ByosConfigForm
        tenantId={activeTenant.id}
        userRole={activeRole as 'owner' | 'manager' | 'member' | 'viewer'}
      />
    </div>
  )
}
