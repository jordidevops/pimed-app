import { getGeocodingOpsSummary } from '@/app/admin/actions/geocoding-settings'
import { AdminGeocodingOpsPanel } from '@/components/dashboard/settings/AdminGeocodingOpsPanel'
import { createSupabaseServerClient } from '@/lib/supabase/server'
import { getT } from '@/lib/i18n/server'

export default async function GeocodingSettingsPage() {
  const t = getT('settings')
  const summary = await getGeocodingOpsSummary()

  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  const role = user?.app_metadata?.role as string | undefined
  const canEdit = role === 'admin'

  return (
    <div className="space-y-10">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">
          {t('settings.geocoding.title', 'Geocoding / Nominatim')}
        </h1>
        <p className="text-gray-500 mt-1 text-sm max-w-2xl">
          {t(
            'settings.geocoding.description',
            'Operativa del fallback Nominatim públic (S10): límit global per IP de plataforma, kill switch i alertes d’abús. No hi ha compte gratuït OSM; el camí de volum és Google BYO.',
          )}
        </p>
      </div>

      <AdminGeocodingOpsPanel initial={summary} canEdit={canEdit} />
    </div>
  )
}
