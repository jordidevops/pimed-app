import {
  listPlatformChecklistTemplates,
  listPlatformResponseSets,
} from '@/app/admin/actions/checklist-templates'
import { PlatformChecklistTemplatesPanel } from '@/components/dashboard/settings/PlatformChecklistTemplatesPanel'
import { createSupabaseServerClient } from '@/lib/supabase/server'

export default async function ChecklistTemplatesSettingsPage() {
  const [initial, responseSets] = await Promise.all([
    listPlatformChecklistTemplates(),
    listPlatformResponseSets(),
  ])

  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  const canEdit = user?.app_metadata?.role === 'admin'

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">
          Plantilles de checklist de plataforma
        </h1>
        <p className="mt-1 max-w-2xl text-sm text-gray-500">
          Les versions publicades són immutables i són les úniques que els plans de manteniment i
          els tenants poden usar. Per canviar-ne el contingut cal obrir un nou esborrany.
        </p>
      </div>

      <PlatformChecklistTemplatesPanel
        initial={initial}
        responseSets={responseSets}
        canEdit={canEdit}
      />
    </div>
  )
}
