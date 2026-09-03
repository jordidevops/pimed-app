import { getPlatformDocumentTemplates } from '@/app/admin/actions/document-templates'
import { AdminPlatformDocumentTemplates } from '@/components/dashboard/settings/AdminPlatformDocumentTemplates'
import { getT } from '@/lib/i18n/server'

export default async function TemplatesSettingsPage() {
  const t = getT('settings')
  const templates = await getPlatformDocumentTemplates()

  return (
    <div className="space-y-10">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">
          {t('settings.templates.title', 'Plantilles Documentals de Plataforma')}
        </h1>
        <p className="text-gray-500 mt-1 text-sm">
          {t(
            'settings.templates.description',
            'Gestiona les plantilles DOCX/HTML de plataforma disponibles per a tots els tenants. Els tenants poden clonar-les i personalitzar-les.',
          )}
        </p>
      </div>

      <AdminPlatformDocumentTemplates initialTemplates={templates} />
    </div>
  )
}
