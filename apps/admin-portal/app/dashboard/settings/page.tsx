import { getAuthSettings, getOnboardingSettings } from '@/app/admin/actions/control-plane'
import { SystemSettingsForm } from '@/components/dashboard/settings/SystemSettingsForm'
import { getT } from '@/lib/i18n/server'

export default async function SettingsPage() {
  const t = getT('settings')
  const [auth, onboarding] = await Promise.all([
    getAuthSettings(),
    getOnboardingSettings(),
  ])

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">{t('settings.system.title', 'Configuració del Sistema')}</h1>
        <p className="text-gray-500 mt-1 text-sm">
          {t('settings.system.description', "Configuració global de la plataforma. Els canvis s'apliquen a tots els tenants.")}
        </p>
      </div>

      <SystemSettingsForm initialAuth={auth} initialOnboarding={onboarding} />
    </div>
  )
}
