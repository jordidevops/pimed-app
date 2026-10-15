import {
  getCalculatorCatalogSettings,
  listPlatformCalculators,
} from '@/app/admin/actions/price-calculators'
import { PlatformPriceCalculatorsPanel } from '@/components/dashboard/settings/PlatformPriceCalculatorsPanel'
import { createSupabaseServerClient } from '@/lib/supabase/server'

export default async function PriceCalculatorsSettingsPage() {
  const [initial, settings] = await Promise.all([
    listPlatformCalculators(),
    getCalculatorCatalogSettings(),
  ])

  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  const canEdit = user?.app_metadata?.role === 'admin'

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Calculadores de preu</h1>
        <p className="mt-1 max-w-2xl text-sm text-gray-500">
          Catàleg de plataforma que els tenants clonen a la biblioteca. Assigna arquetips i
          controla si poden veure models d&apos;altres verticals.
        </p>
      </div>

      <PlatformPriceCalculatorsPanel initial={initial} settings={settings} canEdit={canEdit} />
    </div>
  )
}
