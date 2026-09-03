import { useTranslation } from 'react-i18next'
import { useTenant } from '../../contexts/TenantContext'
import { RolePermissionsEditor } from '../../components/settings/RolePermissionsEditor'

export function PermissionsPage() {
  const { t } = useTranslation('settings')
  const { activeRole } = useTenant()

  const isOwner = activeRole === 'owner'

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-foreground">
          {t('permissions.page_title', 'Permisos de rols')}
        </h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          {t(
            'permissions.page_description',
            'Defineix quines accions pot fer cada rol dins de l\'organització. Els canvis afecten tots els membres en el proper inici de sessió.',
          )}
        </p>
      </div>

      <RolePermissionsEditor isOwner={isOwner} />
    </div>
  )
}
