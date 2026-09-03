import { SigningGlobalFlagCard } from '@/components/dashboard/settings/SigningGlobalFlagCard'
import { prisma } from '@/lib/prisma'
import { getT } from '@/lib/i18n/server'

export default async function SigningSettingsPage() {
  const t = getT('settings')
  const signingFlag = await prisma.feature_flags.findUnique({ where: { key: 'tenant_signing_enabled' } })

  return (
    <div className="space-y-10">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">
          {t('settings.signing.title', 'Configuració de Signatures Digitals')}
        </h1>
        <p className="text-gray-500 mt-1 text-sm">
          {t(
            'settings.signing.description',
            'Activa o desactiva la signatura digital per a tots els tenants i gestiona el percentatge de desplegament.',
          )}
        </p>
      </div>

      <SigningGlobalFlagCard
        isEnabled={signingFlag?.is_enabled ?? false}
        rolloutPercentage={signingFlag?.rollout_percentage ?? 0}
      />
    </div>
  )
}
