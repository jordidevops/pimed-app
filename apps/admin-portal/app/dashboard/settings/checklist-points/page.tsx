import {
  getPlatformReviewPointFacets,
  listPlatformReviewPoints,
} from '@/app/admin/actions/checklist-points'
import { PlatformReviewPointsPanel } from '@/components/dashboard/settings/PlatformReviewPointsPanel'
import { createSupabaseServerClient } from '@/lib/supabase/server'

export default async function ChecklistPointsSettingsPage() {
  const [initial, facets] = await Promise.all([
    listPlatformReviewPoints(),
    getPlatformReviewPointFacets(),
  ])

  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  const canEdit = user?.app_metadata?.role === 'admin'

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Punts de revisió de plataforma</h1>
        <p className="mt-1 max-w-2xl text-sm text-gray-500">
          Catàleg base de punts que els tenants clonen. El text es congela dins de cada versió
          publicada de plantilla, així que els canvis aquí només afecten esborranys i clons futurs.
        </p>
      </div>

      <PlatformReviewPointsPanel initial={initial} facets={facets} canEdit={canEdit} />
    </div>
  )
}
