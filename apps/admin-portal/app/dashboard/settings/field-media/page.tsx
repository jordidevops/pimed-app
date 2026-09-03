import { getFieldMediaPlatformSettings } from '@/app/admin/actions/field-media-settings'
import { AdminFieldMediaSettings } from '@/components/dashboard/settings/AdminFieldMediaSettings'

export const metadata = {
  title: 'Field media — Configuració',
}

export default async function FieldMediaSettingsPage() {
  const settings = await getFieldMediaPlatformSettings()

  return (
    <div className="max-w-3xl space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Field media / Fitxers d&apos;obra</h1>
        <p className="mt-1 text-gray-500">
          Defaults de plataforma per compressió i mode d&apos;upload (fallback quan el tenant no
          defineix preferències).
        </p>
      </div>
      <AdminFieldMediaSettings initialSettings={settings} />
    </div>
  )
}
