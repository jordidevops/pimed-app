import { FeatureFlagGlobalCard } from '@/components/dashboard/settings/FeatureFlagGlobalCard'
import { prisma } from '@/lib/prisma'
import { getT } from '@/lib/i18n/server'

export default async function FeatureFlagsSettingsPage() {
  const t = getT('settings')
  const flags = await prisma.feature_flags.findMany({
    orderBy: { key: 'asc' },
  })

  return (
    <div className="space-y-10">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">
          {t('settings.feature_flags.title', 'Feature flags')}
        </h1>
        <p className="text-gray-500 mt-1 text-sm max-w-2xl">
          {t(
            'settings.feature_flags.description',
            'Control global de mòduls i pilots. Els overrides per tenant (fitxa del tenant → tab Feature Flags) tenen prioritat sobre aquests valors.',
          )}
        </p>
      </div>

      {flags.length === 0 ? (
        <p className="text-sm text-gray-400">
          {t('settings.feature_flags.empty', 'No hi ha feature flags a la base de dades.')}
        </p>
      ) : (
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {flags.map((f) => (
            <FeatureFlagGlobalCard
              key={f.key}
              flag={{
                key: f.key,
                description: f.description,
                is_enabled: f.is_enabled,
                rollout_percentage: f.rollout_percentage,
              }}
            />
          ))}
        </div>
      )}
    </div>
  )
}
