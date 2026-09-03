import {
  listPlatformMaintenancePlans,
  listPublishedPlatformTemplates,
} from '@/app/admin/actions/maintenance-plans'
import { PlatformMaintenancePlansPanel } from '@/components/dashboard/settings/PlatformMaintenancePlansPanel'
import { createSupabaseServerClient } from '@/lib/supabase/server'

export default async function MaintenancePlansSettingsPage() {
  const [initial, templates] = await Promise.all([
    listPlatformMaintenancePlans(),
    listPublishedPlatformTemplates(),
  ])

  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  const canEdit = user?.app_metadata?.role === 'admin'

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Plans de manteniment de plataforma</h1>
        <p className="mt-1 max-w-2xl text-sm text-gray-500">
          Biblioteca que els tenants clonen. Els plans de plataforma no s'assignen mai directament:
          el tenant en fa un clon i assigna el seu.
        </p>
      </div>

      <PlatformMaintenancePlansPanel initial={initial} templates={templates} canEdit={canEdit} />
    </div>
  )
}
