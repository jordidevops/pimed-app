import { useTranslation } from 'react-i18next'
import { useTenant } from '../../contexts/TenantContext'
import { useAuth } from '../../contexts/AuthContext'
import { MembersSettingsSection } from '../../components/settings/MembersSettingsSection'

export function MembersPage() {
  const { t } = useTranslation('settings')
  const { activeTenant, sites } = useTenant()
  const { user } = useAuth()

  if (!activeTenant || !user) return null

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-foreground">
          {t('tabs.members', 'Membres')}
        </h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          {t('members.page_description', "Gestiona els membres i els seus rols dins de l'organització.")}
        </p>
      </div>
      <MembersSettingsSection
        activeTenant={activeTenant}
        userId={user.id}
        sites={sites}
      />
    </div>
  )
}
