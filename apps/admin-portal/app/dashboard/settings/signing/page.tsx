import { SigningGlobalFlagCard } from '@/components/dashboard/settings/SigningGlobalFlagCard'
import { AdminNativeSigningSettings } from '@/components/dashboard/settings/AdminNativeSigningSettings'
import { getPdfConverterSettings } from '@/app/admin/actions/pdf-settings'
import { prisma } from '@/lib/prisma'
import { getT } from '@/lib/i18n/server'

export default async function SigningSettingsPage() {
  const t = getT('settings')
  const [signingFlag, pdfSettings] = await Promise.all([
    prisma.feature_flags.findUnique({ where: { key: 'tenant_signing_enabled' } }),
    getPdfConverterSettings(),
  ])

  return (
    <div className="space-y-10">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">
          {t('settings.signing.title', 'Configuració de Signatures Digitals')}
        </h1>
        <p className="text-gray-500 mt-1 text-sm">
          {t(
            'settings.signing.description',
            'Activa o desactiva la signatura digital per a tots els tenants i configura la firma pròpia.',
          )}
        </p>
      </div>

      <SigningGlobalFlagCard
        isEnabled={signingFlag?.is_enabled ?? false}
        rolloutPercentage={signingFlag?.rollout_percentage ?? 0}
      />

      <div className="max-w-3xl">
        <AdminNativeSigningSettings
          pdfEnabled={pdfSettings.pdf_enabled}
          nativeSigningEnabled={pdfSettings.native_signing_enabled}
          nativeEvidenceMode={pdfSettings.native_evidence_mode}
          remoteSigningTokenDays={pdfSettings.remote_signing_token_days}
          legalFooterText={pdfSettings.legal_footer_text}
        />
      </div>
    </div>
  )
}
