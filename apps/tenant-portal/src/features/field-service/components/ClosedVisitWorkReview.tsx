import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Camera, CheckSquare, ClipboardList, NotebookPen, Package, Paperclip } from 'lucide-react'
import { listRunsForProject } from '../api/checklistTemplatesService'
import { getTasks } from '@/features/projects/api/tasksService'
import { tasksKeys } from '@/features/projects/api/tasksKeys'
import {
  CloseOutAttachmentsPreview,
  CloseOutChecklistsPreview,
  CloseOutMaterialsPreview,
  CloseOutNotesPreview,
  CloseOutPhotosPreview,
  CloseOutReviewCard,
  CloseOutTasksPreview,
} from './CloseOutReview'

const LEGACY_CHECKLIST_TAGS = ['[fs-checklist]', '[migrated-checklist]']

export function ClosedVisitWorkReview({
  projectId,
  notesHtml,
}: {
  projectId: string
  notesHtml?: string | null
}) {
  const { t } = useTranslation('field-service')

  const { data: runs = [] } = useQuery({
    queryKey: ['checklist_runs', projectId],
    queryFn: () => listRunsForProject(projectId),
    enabled: !!projectId,
  })

  const { data: tasks = [] } = useQuery({
    queryKey: tasksKeys.byProject(projectId),
    queryFn: () => getTasks(projectId),
    enabled: !!projectId,
  })

  const activeRuns = runs.filter((run) => run.status !== 'superseded')
  const workTasks = tasks.filter(
    (task) => !LEGACY_CHECKLIST_TAGS.some((tag) => task.title?.includes(tag)),
  )
  const tasksDoneCount = workTasks.filter((task) => task.status === 'done').length
  const tasksOpenCount = workTasks.length - tasksDoneCount

  return (
    <div className="space-y-3">
      {activeRuns.length > 0 ? (
        <div className="rounded-xl border border-border p-3">
          <CloseOutChecklistsPreview runs={activeRuns} />
        </div>
      ) : (
        <CloseOutReviewCard
          title={t('closeout.checklist_summary', 'Checklists')}
          icon={ClipboardList}
        >
          <p className="text-sm text-muted-foreground">
            {t('checklist.empty', 'Cap ítem de checklist')}
          </p>
        </CloseOutReviewCard>
      )}

      <CloseOutReviewCard title={t('work_notes.title', 'Notes de feina')} icon={NotebookPen}>
        <CloseOutNotesPreview html={notesHtml} />
      </CloseOutReviewCard>

      <CloseOutReviewCard title={t('photos.title', 'Fotos')} icon={Camera}>
        <CloseOutPhotosPreview projectId={projectId} />
      </CloseOutReviewCard>

      <CloseOutReviewCard title={t('attachments.title', 'Adjunts')} icon={Paperclip}>
        <CloseOutAttachmentsPreview projectId={projectId} />
      </CloseOutReviewCard>

      <CloseOutReviewCard title={t('materials.title', 'Materials')} icon={Package}>
        <CloseOutMaterialsPreview projectId={projectId} />
      </CloseOutReviewCard>

      <CloseOutReviewCard title={t('closeout.tasks_summary', 'Tasques')} icon={CheckSquare}>
        <CloseOutTasksPreview
          tasks={workTasks}
          doneCount={tasksDoneCount}
          openCount={tasksOpenCount}
        />
      </CloseOutReviewCard>
    </div>
  )
}
