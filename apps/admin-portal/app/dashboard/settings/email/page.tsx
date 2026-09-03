import { getRateLimitingSettings, getEmailModuleSettings } from '@/app/admin/actions/email-settings'
import { getPlatformEmailTemplates } from '@/app/admin/actions/email-templates'
import { AdminEmailSettings } from '@/components/dashboard/settings/AdminEmailSettings'
import { AdminPlatformTemplates } from '@/components/dashboard/settings/AdminPlatformTemplates'
import { getT } from '@/lib/i18n/server'

export default async function EmailSettingsPage() {
  const t = getT('settings')
  const [rateLimiting, email, platformTemplates] = await Promise.all([
    getRateLimitingSettings(),
    getEmailModuleSettings(),
    getPlatformEmailTemplates(),
  ])

  return (
    <div className="space-y-10">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">{t('settings.email.title', "Configuració d'Infraestructura d'Email")}</h1>
        <p className="text-gray-500 mt-1 text-sm">
          {t('settings.email.description', 'Paràmetres globals d\'email i rate limiting. Els canvis afecten tots els tenants sense BYOS configurat.')}
        </p>
      </div>

      <AdminEmailSettings initialRateLimiting={rateLimiting} initialEmail={email} />

      <div>
        <h2 className="text-lg font-semibold text-gray-900 mb-1">
          {t('settings.email.templates.section_title', 'Plantilles de Plataforma')}
        </h2>
        <p className="text-gray-500 text-sm mb-6">
          {t(
            'settings.email.templates.section_desc',
            "Layouts i plantilles de contingut base disponibles per a tots els tenants. Els tenants poden crear les seves pròpies versions per sobreescriure-les.",
          )}
        </p>
        <AdminPlatformTemplates initialTemplates={platformTemplates} />
      </div>
    </div>
  )
}
