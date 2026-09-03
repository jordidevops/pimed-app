import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ExternalLink, GitBranchPlus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { useToast } from '@/hooks/use-toast'
import { useOnlineStatus } from '@/hooks/useOnlineStatus'
import { useTenant } from '@/contexts/TenantContext'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import {
  createFollowUpWorkOrder,
  listFollowUpProjects,
} from '@/features/projects/api/projectsService'
import { getTasks } from '@/features/projects/api/tasksService'
import { projectsKeys } from '@/features/projects/api/projectsKeys'
import { tasksKeys } from '@/features/projects/api/tasksKeys'
import {
  getProjectStatusClass,
  getProjectStatusLabel,
  getProjectStatusVariant,
} from '@/features/projects/projectStatus'

interface FollowUpOrdersSectionProps {
  projectId: string
  /** Show create button when there are deferred findings to chase. */
  canCreate?: boolean
  compact?: boolean
  /** Drives create button label (repair vs follow-up). */
  visitIntent?: 'inspection' | 'corrective' | 'generic' | null
}

export function FollowUpOrdersSection({
  projectId,
  canCreate = true,
  compact = false,
  visitIntent = 'generic',
}: FollowUpOrdersSectionProps) {
  const { t } = useTranslation(['field-service', 'projects'])
  const { toast } = useToast()
  const isOnline = useOnlineStatus()
  const isFieldService = useIsFieldService()
  const { activeTenant } = useTenant()
  const queryClient = useQueryClient()
  const [creating, setCreating] = useState(false)

  const { data: followUps = [] } = useQuery({
    queryKey: [...projectsKeys.detail(projectId), 'follow_ups'],
    queryFn: () => listFollowUpProjects(projectId),
    enabled: !!projectId,
  })

  const followUpIdsKey = followUps.map((fu) => fu.id).filter(Boolean).join(',')

  const { data: followUpTaskMeta = [] } = useQuery({
    queryKey: [...projectsKeys.detail(projectId), 'follow_ups', 'task_meta', followUpIdsKey],
    queryFn: async () => {
      const rows = await Promise.all(
        followUps.map(async (fu) => {
          const tasks = await getTasks(fu.id!)
          const findingTasks = tasks.filter((task) => task.source_checklist_run_item_id)
          return {
            id: fu.id!,
            taskCount: findingTasks.length,
            preview: findingTasks[0]?.title ?? null,
          }
        }),
      )
      return rows
    },
    enabled: followUps.length > 0,
  })

  const metaById = new Map(followUpTaskMeta.map((m) => [m.id, m]))

  const detailBase = isFieldService ? '/field/orders' : '/projects'
  const isInspection = visitIntent === 'inspection'
  const createLabel = creating
    ? t('field-service:follow_up.creating', 'Creant…')
    : isInspection
      ? t('field-service:follow_up.generate_repair', 'Generar reparació')
      : t('field-service:follow_up.create', 'Crear OS de seguiment')
  const emptyHint = isInspection
    ? t(
        'field-service:follow_up.repair_hint',
        'Genera una OS de reparació amb el mateix client/ubicació i trasllada les tasques diferides. Continuaràs a aquesta visita.',
      )
    : t(
        'field-service:follow_up.empty_hint',
        'Crea una OS nova amb el mateix client/ubicació i trasllada les tasques diferides. Continuaràs a aquesta visita.',
      )

  async function handleCreate() {
    if (!isOnline) {
      toast({
        variant: 'destructive',
        description: t(
          'field-service:follow_up.requires_online',
          'Cal connexió per crear l\'ordre de seguiment',
        ),
      })
      return
    }
    setCreating(true)
    try {
      const result = await createFollowUpWorkOrder({
        sourceProjectId: projectId,
        moveOpenTasks: true,
      })
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: projectsKeys.detail(projectId) }),
        queryClient.invalidateQueries({
          queryKey: [...projectsKeys.detail(projectId), 'follow_ups'],
        }),
        queryClient.invalidateQueries({
          queryKey: [...projectsKeys.detail(projectId), 'follow_ups', 'task_meta'],
        }),
        queryClient.invalidateQueries({ queryKey: tasksKeys.byProject(projectId) }),
        queryClient.invalidateQueries({
          queryKey: ['checklist_closeout_blockers', projectId],
        }),
        queryClient.invalidateQueries({ queryKey: tasksKeys.byProject(result.project_id) }),
        ...(activeTenant?.id
          ? [queryClient.invalidateQueries({ queryKey: projectsKeys.all(activeTenant.id) })]
          : []),
      ])
      toast({
        description:
          result.moved_task_count > 0
            ? t(
                'field-service:follow_up.created_with_tasks_stay',
                'OS de reparació creada ({{n}} tasques). Continues a la visita actual.',
                { n: result.moved_task_count },
              )
            : t(
                'field-service:follow_up.created_stay',
                'Ordre de seguiment creada. Continues a la visita actual.',
              ),
      })
    } catch {
      toast({
        variant: 'destructive',
        description: t(
          'field-service:follow_up.create_failed',
          'No s\'ha pogut crear l\'ordre de seguiment',
        ),
      })
    } finally {
      setCreating(false)
    }
  }

  if (!canCreate && followUps.length === 0) return null

  return (
    <div
      className={
        compact
          ? 'space-y-2'
          : 'rounded-lg border border-border p-3 space-y-2'
      }
    >
      <div className="flex items-center justify-between gap-2">
        <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
          {t('field-service:follow_up.title', 'Ordres de seguiment')}
        </p>
        {canCreate && (
          <Button
            size="sm"
            variant="outline"
            className="h-8 gap-1.5"
            disabled={!isOnline || creating}
            onClick={() => void handleCreate()}
          >
            <GitBranchPlus className="h-3.5 w-3.5" />
            {createLabel}
          </Button>
        )}
      </div>

      {followUps.length === 0 ? (
        canCreate && (
          <p className="text-xs text-muted-foreground">{emptyHint}</p>
        )
      ) : (
        <ul className="space-y-1.5">
          {followUps.map((fu) => {
            const meta = metaById.get(fu.id!)
            return (
              <li key={fu.id}>
                <Link
                  to={`${detailBase}/${fu.id}`}
                  className="flex items-start gap-2 rounded-md border border-border px-2.5 py-2 text-sm hover:bg-muted/40"
                >
                  <Badge
                    variant={getProjectStatusVariant(fu.status)}
                    className={`text-[10px] shrink-0 mt-0.5 ${getProjectStatusClass(fu.status)}`}
                  >
                    {getProjectStatusLabel(t, fu.status, { fieldService: isFieldService })}
                  </Badge>
                  <span className="min-w-0 flex-1">
                    <span className="block truncate font-medium">{fu.name}</span>
                    {meta && meta.taskCount > 0 && (
                      <span className="block text-[11px] text-muted-foreground truncate">
                        {t('field-service:follow_up.tasks_count', '{{n}} tasques', {
                          n: meta.taskCount,
                        })}
                        {meta.preview ? ` · ${meta.preview}` : ''}
                      </span>
                    )}
                    {meta && meta.taskCount === 0 && (
                      <span className="block text-[11px] text-muted-foreground">
                        {t('field-service:follow_up.no_tasks', 'Sense tasques traslladades')}
                      </span>
                    )}
                  </span>
                  <ExternalLink className="h-3.5 w-3.5 text-muted-foreground shrink-0 mt-0.5" />
                </Link>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
