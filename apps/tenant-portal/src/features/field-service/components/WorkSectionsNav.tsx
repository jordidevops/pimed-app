import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Badge } from '@/components/ui/badge'
import { listRunsForProject, isFindingItem } from '../api/checklistTemplatesService'
import { getProjectMaterials } from '../api/materialsService'
import { getTasks } from '@/features/projects/api/tasksService'
import { supabase } from '@/lib/supabase'

interface WorkSectionsNavProps {
  projectId: string
  hasWorkNotes?: boolean
  /** When embedded under a sticky Feina header, drop own sticky. */
  embedded?: boolean
}

const SECTIONS = [
  { id: 'work-checklist', labelKey: 'detail.nav_checklist', fallback: 'Checklist' },
  { id: 'work-notes', labelKey: 'detail.nav_notes', fallback: 'Notes' },
  { id: 'work-photos', labelKey: 'detail.nav_photos', fallback: 'Fotos' },
  { id: 'work-attachments', labelKey: 'detail.nav_attachments', fallback: 'Adjunts' },
  { id: 'work-materials', labelKey: 'detail.nav_materials', fallback: 'Materials' },
  { id: 'work-tasks', labelKey: 'detail.nav_tasks', fallback: 'Tasques' },
] as const

export function WorkSectionsNav({ projectId, hasWorkNotes, embedded = false }: WorkSectionsNavProps) {
  const { t } = useTranslation('field-service')

  const { data: runs = [] } = useQuery({
    queryKey: ['checklist_runs', projectId],
    queryFn: () => listRunsForProject(projectId),
    enabled: !!projectId,
  })

  const { data: materials = [] } = useQuery({
    queryKey: ['project_materials', projectId],
    queryFn: () => getProjectMaterials(projectId),
    enabled: !!projectId,
  })

  const { data: tasks = [] } = useQuery({
    queryKey: ['projects', 'tasks', projectId, 'work-nav'],
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

  const openFindings = runs
    .filter((r) => r.status !== 'superseded')
    .flatMap((r) => r.items ?? [])
    .filter(
      (i) =>
        isFindingItem(i) &&
        (i.resolution_status === 'open' || i.resolution_status === 'deferred'),
    ).length

  const openTasks = tasks.filter((task) => task.status !== 'done').length

  const badges: Record<string, number | null> = {
    'work-checklist': openFindings > 0 ? openFindings : null,
    'work-notes': hasWorkNotes ? 1 : null,
    'work-photos': photoCount > 0 ? photoCount : null,
    'work-attachments': attachmentCount > 0 ? attachmentCount : null,
    'work-materials': materials.length > 0 ? materials.length : null,
    'work-tasks': openTasks > 0 ? openTasks : null,
  }

  return (
    <nav
      aria-label={t('detail.nav_aria', 'Apartats de la feina')}
      className={
        embedded
          ? '-mx-1 flex gap-1 overflow-x-auto px-1 py-1.5'
          : 'sticky top-0 z-10 -mx-1 flex gap-1 overflow-x-auto bg-background/95 px-1 py-2 backdrop-blur supports-[backdrop-filter]:bg-background/80'
      }
    >
      {SECTIONS.map((s) => {
        const count = badges[s.id]
        return (
          <a
            key={s.id}
            href={`#${s.id}`}
            className="inline-flex shrink-0 items-center gap-1.5 rounded-md border border-border px-2.5 py-1.5 text-xs font-medium text-muted-foreground hover:bg-muted/50 hover:text-foreground"
            onClick={(e) => {
              e.preventDefault()
              const main = document.querySelector('main') as HTMLElement | null
              const el = document.getElementById(s.id)
              if (main && el) {
                const top =
                  el.getBoundingClientRect().top -
                  main.getBoundingClientRect().top +
                  main.scrollTop -
                  120
                main.scrollTo({ top: Math.max(0, top), behavior: 'smooth' })
              } else {
                el?.scrollIntoView({ behavior: 'smooth', block: 'start' })
              }
            }}
          >
            {t(s.labelKey, s.fallback)}
            {count != null && (
              <Badge variant="secondary" className="h-5 min-w-5 px-1 text-[10px]">
                {count}
              </Badge>
            )}
          </a>
        )
      })}
    </nav>
  )
}
