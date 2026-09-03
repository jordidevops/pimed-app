import { listPlatformResponseSetsAdmin } from '@/app/admin/actions/checklist-response-sets'
import { PlatformResponseSetsPanel } from '@/components/dashboard/settings/PlatformResponseSetsPanel'
import { createSupabaseServerClient } from '@/lib/supabase/server'

export default async function ChecklistResponseSetsSettingsPage() {
  const initial = await listPlatformResponseSetsAdmin({ includeArchived: true })

  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  const canEdit = user?.app_metadata?.role === 'admin'

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Conjunts de respostes de plataforma</h1>
        <p className="mt-1 max-w-2xl text-sm text-gray-500">
          Escales de resposta (Conforme/No conforme, semàfor, etc.) que les plantilles de revisió
          usen per defecte. Cada opció porta una semàntica (pass, warning, fail…) que afecta el
          tancament de la visita.
        </p>
      </div>

      <PlatformResponseSetsPanel initial={initial} canEdit={canEdit} />
    </div>
  )
}
