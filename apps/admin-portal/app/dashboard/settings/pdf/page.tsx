import { getPdfConverterSettings } from '@/app/admin/actions/pdf-settings'
import { AdminPdfSettings } from '@/components/dashboard/settings/AdminPdfSettings'
import { getT } from '@/lib/i18n/server'

export const metadata = {
  title: 'PDF — Configuració',
}

export default async function PdfSettingsPage() {
  const t = getT('settings')
  const settings = await getPdfConverterSettings()

  return (
    <div className="max-w-3xl space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">
          {t('settings.pdf.title', 'PDF')}
        </h1>
        <p className="text-gray-500 mt-1">
          {t(
            'settings.pdf.description',
            'Configura el servei Gotenberg i els perfils de generació PDF.',
          )}
        </p>
      </div>
      <AdminPdfSettings initialSettings={settings} />
    </div>
  )
}
