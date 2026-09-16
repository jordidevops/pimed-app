import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { Pencil, Trash2, ChevronRight, Loader2, Pause, Play } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import type { Project, ProjectListItem } from '../api/projectsService'
import { getProjectStatusClass, getProjectStatusLabel, getProjectStatusVariant } from '../projectStatus'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { StartVisitDialog } from '@/features/field-service/components/StartVisitDialog'
import { PaymentPendingChip } from '@/features/commercial/components/PaymentPendingChip'
import { getProjectsPaymentPending } from '@/features/commercial/api/commercialFlowService'
import { DeleteProjectDialog } from './DeleteProjectDialog'
import { formatElapsedSeconds } from '@/lib/dateLocal'

interface ProjectRowProps {
  project: ProjectListItem
  onEdit: (project: Project) => void
  detailBasePath?: string
  sortField?: string
  sortDirection?: 'asc' | 'desc'
  onSort?: (field: string) => void
  /** Open punch project id for the current user (field service). */
  activePunchProjectId?: string | null
  onStopPunch?: () => void
  stopPunchBusy?: boolean
  workedSeconds?: number
}

const TYPE_LABELS: Record<string, string> = {
  internal: 'Intern',
  work_order: 'OT',
  maintenance: 'Manteniment',
}

export function ProjectRow({
  project,
  onEdit,
  detailBasePath = '/projects',
  activePunchProjectId = null,
  onStopPunch,
  stopPunchBusy = false,
  workedSeconds = 0,
}: ProjectRowProps) {
  const { t } = useTranslation(['projects', 'field-service'])
  const isFieldService = useIsFieldService()
  const [startOpen, setStartOpen] = useState(false)
  const [deleteOpen, setDeleteOpen] = useState(false)

  const statusLabel = getProjectStatusLabel(t, project.status, { fieldService: isFieldService })

  const typeLabel = project.type
    ? t(`projects.type.${project.type}`, TYPE_LABELS[project.type] ?? project.type)
    : '—'

  const isPunchActive = !!project.id && project.id === activePunchProjectId

  const { data: paymentPendingMap = {} } = useQuery({
    queryKey: ['payment_pending', project.id],
    queryFn: () => getProjectsPaymentPending(project.id ? [project.id] : []),
    enabled: isFieldService && !!project.id,
    staleTime: 30_000,
  })
  const paymentPending = !!(project.id && paymentPendingMap[project.id])

  const canStartVisit =
    isFieldService
    && !activePunchProjectId
    && project.type === 'work_order'
    && project.status !== 'completed'
    && project.status !== 'cancelled'

  const hideEditDeleteOnMobile = isFieldService

  return (
    <>
      <tr className="hover:bg-muted/30 transition-colors">
        <td className="px-4 py-3">
          <Link
            to={`${detailBasePath}/${project.id}`}
            className="font-medium text-foreground hover:text-primary flex items-center gap-1 group"
          >
            <span className="min-w-0">
              <span className="block truncate">{project.name}</span>
              {(isPunchActive || workedSeconds > 0) && (
                <span className={`block text-xs font-normal tabular-nums ${isPunchActive ? 'text-green-700 dark:text-green-400' : 'text-muted-foreground'}`}>
                  {isPunchActive
                    ? `${t('field-service:today.working', 'Treballant')} · ${formatElapsedSeconds(workedSeconds)}`
                    : formatElapsedSeconds(workedSeconds)}
                </span>
              )}
            </span>
            <ChevronRight className="h-3.5 w-3.5 opacity-0 group-hover:opacity-60 transition-opacity shrink-0" />
          </Link>
        </td>
        <td className="px-4 py-3 hidden md:table-cell">
          <Badge variant="outline" className="text-xs font-normal">
            {typeLabel}
          </Badge>
        </td>
        <td className="px-4 py-3 hidden sm:table-cell">
          <div className="flex flex-wrap items-center gap-1.5">
            {isPunchActive ? (
              <Badge className="bg-green-600 hover:bg-green-600 text-white text-xs">
                {t('field-service:today.working', 'Treballant')}
              </Badge>
            ) : (
              <Badge variant={getProjectStatusVariant(project.status)} className={`text-xs ${getProjectStatusClass(project.status)}`}>
                {statusLabel}
              </Badge>
            )}
            <PaymentPendingChip pending={paymentPending} />
          </div>
        </td>
        <td className="px-4 py-3 hidden lg:table-cell text-muted-foreground">
          {project.pending_task_count ?? 0} / {project.task_count ?? 0}
        </td>
        <td className="px-4 py-3 text-right">
          <div className="flex items-center justify-end gap-1">
            {isPunchActive && (
              <Button
                variant="ghost"
                size="icon"
                className="h-7 w-7 text-destructive hover:text-destructive"
                onClick={onStopPunch}
                disabled={stopPunchBusy}
                aria-label={t('field-service:today.stop_visit', 'Aturar visita')}
              >
                {stopPunchBusy
                  ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  : <Pause className="h-3.5 w-3.5" />}
              </Button>
            )}
            {canStartVisit && (
              <Button
                variant="ghost"
                size="icon"
                className="h-7 w-7"
                onClick={() => setStartOpen(true)}
                aria-label={t('field-service:fab.start', 'Iniciar visita')}
              >
                <Play className="h-3.5 w-3.5" />
              </Button>
            )}
            <Button
              variant="ghost"
              size="icon"
              className={`h-7 w-7 ${hideEditDeleteOnMobile ? 'hidden md:inline-flex' : ''}`}
              onClick={() => onEdit(project)}
              aria-label={t('projects.list.edit_aria', 'Editar projecte')}
            >
              <Pencil className="h-3.5 w-3.5" />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              className={`h-7 w-7 text-destructive hover:text-destructive ${hideEditDeleteOnMobile ? 'hidden md:inline-flex' : ''}`}
              onClick={() => setDeleteOpen(true)}
              aria-label={t('projects.list.delete_aria', 'Eliminar projecte')}
            >
              <Trash2 className="h-3.5 w-3.5" />
            </Button>
          </div>
        </td>
      </tr>
      {canStartVisit && (
        <StartVisitDialog
          open={startOpen}
          onOpenChange={setStartOpen}
          orders={[project]}
          initialOrderId={project.id}
        />
      )}
      <DeleteProjectDialog
        projectId={project.id}
        projectName={project.name}
        open={deleteOpen}
        onOpenChange={setDeleteOpen}
      />
    </>
  )
}
