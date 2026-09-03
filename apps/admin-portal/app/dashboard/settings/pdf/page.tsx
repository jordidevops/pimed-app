import { getPdfConverterSettings } from '@/app/admin/actions/pdf-settings'
import { AdminPdfSettings } from '@/components/dashboard/settings/AdminPdfSettings'

export const metadata = {
  title: 'PDF & Firma Pròpia — Configuració',
}

export default async function PdfSettingsPage() {
  const settings = await getPdfConverterSettings()

  return (
    <div className="max-w-3xl space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">PDF & Firma Pròpia</h1>
        <p className="text-gray-500 mt-1">
          Configura el servei Gotenberg, els perfils PDF i el mòdul de signatura nativa.
        </p>
      </div>
      <AdminPdfSettings initialSettings={settings} />
    </div>
  )
}
