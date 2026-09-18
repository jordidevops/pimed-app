import { getAiModelCapabilitiesAdmin, getPlatformAiDefaults, getPlatformAiFeaturePrompts } from '@/app/admin/actions/ai-settings'
import { AdminAiSettings } from '@/components/dashboard/settings/AdminAiSettings'
import { AdminAiModelCapabilities } from '@/components/dashboard/settings/AdminAiModelCapabilities'
import { AdminAiFeaturePrompts } from '@/components/dashboard/settings/AdminAiFeaturePrompts'
import { getT } from '@/lib/i18n/server'

export default async function AiSettingsPage() {
  const t = getT('settings')
  const [defaults, capabilities, featurePrompts] = await Promise.all([
    getPlatformAiDefaults(),
    getAiModelCapabilitiesAdmin({ includeDeprecated: true }),
    getPlatformAiFeaturePrompts(),
  ])

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">
          {t('settings.ai.title', 'Configuració IA (plataforma)')}
        </h1>
        <p className="text-gray-500 mt-1 text-sm">
          {t(
            'settings.ai.pageDescription',
            'Defaults globals per proveïdor: models suggerits, enllaços de facturació i paràmetres de generació.',
          )}
        </p>
      </div>

      <AdminAiFeaturePrompts prompts={featurePrompts} />
      <AdminAiSettings defaults={defaults} />
      <AdminAiModelCapabilities rows={capabilities} />
    </div>
  )
}
