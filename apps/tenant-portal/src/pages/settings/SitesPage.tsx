import { useTranslation } from 'react-i18next'
import { useTenant } from '../../contexts/TenantContext'
import { useAuth } from '../../contexts/AuthContext'
import { SitesSettingsSection } from '../../components/settings/SitesSettingsSection'

export function SitesPage() {
  const { t } = useTranslation('settings')
  const { activeTenant, sites } = useTenant()
  const { user } = useAuth()

  if (!activeTenant || !user) return null

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-foreground">
          {t('tabs.sites', 'Locals')}
        </h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          {t('sites.page_description', "Gestiona els locals i seus de l'organització.")}
        </p>
      </div>
      <SitesSettingsSection
        activeTenant={activeTenant}
        userId={user.id}
        sites={sites}
      />
    </div>
  )
}
