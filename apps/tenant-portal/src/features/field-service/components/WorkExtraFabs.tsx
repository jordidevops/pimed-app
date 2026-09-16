import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Camera, CheckSquare, Package, Paperclip, type LucideIcon } from 'lucide-react'
import { getProjectMaterials } from '../api/materialsService'
import { getTasks } from '@/features/projects/api/tasksService'
import { tasksKeys } from '@/features/projects/api/tasksKeys'
import { supabase } from '@/lib/supabase'
import { cn } from '@/lib/utils'
import { useTenant } from '@/contexts/TenantContext'
import { useProjectFieldOps } from '../hooks/useProjectFieldOps'

export type WorkExtraSection = 'photos' | 'attachments' | 'materials' | 'tasks'

interface WorkExtraFabsProps {
  projectId: string
  active: WorkExtraSection | null
  onChange: (next: WorkExtraSection | null) => void
}

const ITEMS: {
  id: WorkExtraSection
  labelKey: string
  fallback: string
  icon: LucideIcon
}[] = [
  { id: 'photos', labelKey: 'detail.nav_photos', fallback: 'Fotos', icon: Camera },
  { id: 'attachments', labelKey: 'detail.nav_attachments', fallback: 'Adjunts', icon: Paperclip },
  { id: 'materials', labelKey: 'detail.nav_materials', fallback: 'Materials', icon: Package },
  { id: 'tasks', labelKey: 'detail.nav_tasks', fallback: 'Tasques', icon: CheckSquare },
]

export function WorkExtraFabs({ projectId, active, onChange }: WorkExtraFabsProps) {
  const { t } = useTranslation('field-service')
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id
  const localOps = useProjectFieldOps(tenantId, projectId)

  const { data: materials = [] } = useQuery({
    queryKey: ['project_materials', projectId, tenantId],
    queryFn: () => getProjectMaterials(projectId, tenantId),
    enabled: !!projectId,
  })

  const { data: tasks = [] } = useQuery({
    queryKey: tasksKeys.byProject(projectId),
    queryFn: () => getTasks(projectId),
    enabled: !!projectId,
  })

  const { data: photoCount = 0 } = useQuery({
    queryKey: ['project_photos_count', projectId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('file_nodes')
        .select('id, metadata')
        .eq('entity_type', 'project')
        .eq('entity_id', projectId)
        .eq('node_type', 'file')
        .neq('processing_status', 'pending')
      if (error) throw error
      return (data ?? []).filter((n) => {
        const m = n.metadata as Record<string, unknown> | null
        return m?.purpose === 'field_photo' && m?.variant !== 'light'
      }).length
    },
    enabled: !!projectId,
  })

  const { data: attachmentCount = 0 } = useQuery({
    queryKey: ['project_attachments_count', projectId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('file_nodes')
        .select('id, metadata')
        .eq('entity_type', 'project')
        .eq('entity_id', projectId)
        .eq('node_type', 'file')
        .neq('processing_status', 'pending')
      if (error) throw error
      return (data ?? []).filter((n) => {
        const m = n.metadata as Record<string, unknown> | null
        return m?.purpose === 'field_attachment'
      }).length
    },
    enabled: !!projectId,
  })

  const openTasks = tasks.filter((task) => task.status !== 'done').length

  const badges: Record<WorkExtraSection, number | null> = {
    photos: photoCount > 0 ? photoCount : null,
    attachments: attachmentCount > 0 ? attachmentCount : null,
    materials: materials.length + localOps.materials.length > 0
      ? materials.length + localOps.materials.length
      : null,
    tasks: openTasks > 0 ? openTasks : null,
  }

  return (
    <nav
      aria-label={t('detail.extra_aria', 'Afegir a la feina')}
      className="grid grid-cols-4 gap-2 px-0.5"
    >
      {ITEMS.map((item) => {
        const isActive = active === item.id
        const count = badges[item.id]
        const label = t(item.labelKey, item.fallback)
        const Icon = item.icon
        return (
          <button
            key={item.id}
            type="button"
            aria-pressed={isActive}
            aria-controls={`work-${item.id}`}
            aria-label={
              isActive
                ? t('detail.extra_hide', 'Amagar {{section}}', { section: label })
                : t('detail.extra_show', 'Mostrar {{section}}', { section: label })
            }
            className="flex min-w-0 flex-col items-center gap-1.5 rounded-xl px-1 py-1 text-muted-foreground hover:text-foreground"
            onClick={() => onChange(isActive ? null : item.id)}
          >
            <span
              className={cn(
                'relative flex h-14 w-14 items-center justify-center rounded-full shadow-md transition-colors',
                isActive
                  ? 'bg-primary text-primary-foreground'
                  : 'bg-muted text-foreground',
              )}
            >
              <Icon className="h-6 w-6" />
              {count != null && (
                <span className="absolute -right-0.5 -top-0.5 z-10 flex h-5 min-w-5 items-center justify-center rounded-full bg-sky-600 px-1 text-[10px] font-bold text-white shadow-sm ring-2 ring-background dark:bg-sky-500">
                  {count}
                </span>
              )}
            </span>
            <span className="max-w-full truncate text-center text-xs font-medium leading-tight">
              {label}
            </span>
          </button>
        )
      })}
    </nav>
  )
}
