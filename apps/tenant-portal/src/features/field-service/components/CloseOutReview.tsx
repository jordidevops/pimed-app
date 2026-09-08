import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import type { ReactNode } from 'react'
import { CheckCircle2, Circle, ExternalLink, FileText, Pencil, type LucideIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { getFileUrl } from '@/features/storage/api/storageService'
import type { Task } from '@/features/projects/api/tasksService'
import {
  fieldMediaKeys,
  listFieldMedia,
  listProjectAttachments,
  listProjectPhotos,
  type FieldMediaNode,
} from '../api/fieldMediaService'
import { getProjectMaterials } from '../api/materialsService'
import {
  isRunItemAnswered,
  runProgress,
  type ChecklistRun,
} from '../api/checklistTemplatesService'
import { FieldPhotoGallery } from './FieldPhotoGallery'

function htmlHasText(html?: string | null) {
  return Boolean(
    html
      ?.replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/gi, ' ')
      .trim(),
  )
}

function formatBytes(n: number | null | undefined): string {
  if (n == null || n <= 0) return ''
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

function attachmentKind(node: FieldMediaNode): string {
  const mime = (node.mime_type ?? '').toLowerCase()
  const name = node.name.toLowerCase()
  if (mime.includes('pdf') || name.endsWith('.pdf')) return 'PDF'
  if (mime.includes('word') || /\.docx?$/.test(name)) return 'Word'
  if (mime.includes('excel') || mime.includes('spreadsheet') || /\.xlsx?$/.test(name)) return 'Excel'
  if (mime.startsWith('text/') || name.endsWith('.txt')) return 'Text'
  if (name.endsWith('.odt')) return 'ODT'
  if (name.endsWith('.ods')) return 'ODS'
  return node.mime_type?.split('/').pop()?.toUpperCase() || ''
}

function canOpenAttachment(node: FieldMediaNode): boolean {
  const mime = (node.mime_type ?? '').toLowerCase()
  const name = node.name.toLowerCase()
  return (
    mime.startsWith('image/') ||
    mime === 'application/pdf' ||
    mime === 'text/plain' ||
    mime.includes('word') ||
    mime.includes('excel') ||
    mime.includes('spreadsheet') ||
    mime.includes('opendocument') ||
    /\.(pdf|png|jpe?g|gif|webp|txt|docx?|xlsx?|odt|ods)$/i.test(name)
  )
}

export type CloseOutEditSection = 'notes' | 'photos' | 'attachments' | 'materials'

export function CloseOutReviewCard({
  title,
  icon: Icon,
  editing,
  onToggleEdit,
  children,
}: {
  title: string
  icon: LucideIcon
  editing?: boolean
  onToggleEdit?: () => void
  children: ReactNode
}) {
  const { t } = useTranslation('field-service')
  return (
    <div className="space-y-2 rounded-xl border border-border p-3">
      <div className="flex items-center justify-between gap-2">
        <h3 className="flex items-center gap-2 text-sm font-medium">
          <Icon className="h-4 w-4" />
          {title}
        </h3>
        {onToggleEdit && (
          <Button
            type="button"
            size="icon"
            variant={editing ? 'secondary' : 'ghost'}
            className="h-8 w-8"
            aria-pressed={editing}
            aria-label={
              editing
                ? t('closeout.back_to_review', 'Tornar a la revisió')
                : t('closeout.edit', 'Editar')
            }
            onClick={onToggleEdit}
          >
            <Pencil className="h-4 w-4" />
          </Button>
        )}
      </div>
      {children}
    </div>
  )
}

export function CloseOutChecklistsPreview({ runs }: { runs: ChecklistRun[] }) {
  const { t } = useTranslation('field-service')

  return (
    <div className="space-y-3">
      <p className="text-sm font-medium">{t('closeout.checklist_summary', 'Checklists')}</p>
      {runs.map((run) => {
        const progress = runProgress(run)
        const items = [...(run.items ?? [])].sort((a, b) => a.position - b.position)
        const pendingRequired = items.filter((i) => i.is_required && !isRunItemAnswered(i)).length
        return (
          <div key={run.id} className="space-y-1.5 rounded-lg border border-border/80 p-2.5">
            <p className="text-sm font-medium">{run.name_snapshot}</p>
            <p className="text-xs text-muted-foreground">
              {progress.answered}/{progress.total}
              {pendingRequired > 0 && (
                <span className="ml-1 text-destructive">
                  ({t('closeout.pending_required', '{{n}} obligatoris pendents', { n: pendingRequired })})
                </span>
              )}
            </p>
            {items.length === 0 ? (
              <p className="text-xs text-muted-foreground">
                {t('checklist.empty', 'Cap ítem de checklist')}
              </p>
            ) : (
              <ul className="space-y-1.5">
                {items.map((item) => {
                  const done = isRunItemAnswered(item)
                  const note = item.note?.trim()
                  const answer =
                    item.response_type !== 'checkbox' ? item.answer_label?.trim() : null
                  return (
                    <li key={item.id} className="flex items-start gap-2">
                      {done ? (
                        <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-emerald-600 dark:text-emerald-400" />
                      ) : (
                        <Circle className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
                      )}
                      <div className="min-w-0 flex-1">
                        <p
                          className={
                            done
                              ? 'text-sm text-muted-foreground'
                              : 'text-sm text-foreground'
                          }
                        >
                          {item.title}
                          {answer ? (
                            <span className="ml-1 font-normal text-muted-foreground">
                              · {answer}
                            </span>
                          ) : null}
                        </p>
                        {note ? (
                          <p className="mt-0.5 whitespace-pre-wrap text-xs text-muted-foreground">
                            {note}
                          </p>
                        ) : null}
                      </div>
                    </li>
                  )
                })}
              </ul>
            )}
          </div>
        )
      })}
    </div>
  )
}

export function CloseOutNotesPreview({ html }: { html?: string | null }) {
  const { t } = useTranslation('field-service')
  if (!htmlHasText(html)) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('work_notes.empty', 'Cap nota encara')}
      </p>
    )
  }
  return (
    <div
      className="prose prose-sm dark:prose-invert max-w-none rounded-md border border-border px-3 py-2 [&_a]:text-primary [&_a]:underline"
      dangerouslySetInnerHTML={{ __html: html ?? '' }}
    />
  )
}

export function CloseOutPhotosPreview({ projectId }: { projectId: string }) {
  const { t } = useTranslation('field-service')
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id
  const { data: photos = [], isLoading } = useQuery({
    queryKey: fieldMediaKeys.photos(tenantId ?? '', projectId),
    queryFn: () => listProjectPhotos(tenantId!, projectId),
    enabled: !!tenantId && !!projectId,
  })

  if (isLoading) {
    return <p className="text-sm text-muted-foreground">{t('photos.loading', 'Carregant…')}</p>
  }
  if (!tenantId) return null
  return (
    <FieldPhotoGallery
      photos={photos}
      tenantId={tenantId}
      emptyText={t('photos.empty', 'Cap foto encara')}
    />
  )
}

export function CloseOutAttachmentsPreview({ projectId }: { projectId: string }) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id
  const { data: attachments = [], isLoading } = useQuery({
    queryKey: fieldMediaKeys.attachments(tenantId ?? '', projectId),
    queryFn: () => listProjectAttachments(tenantId!, projectId),
    enabled: !!tenantId && !!projectId,
  })

  async function openNode(node: FieldMediaNode) {
    if (!tenantId) return
    try {
      const { url } = await getFileUrl(node.id, 3600, tenantId, false)
      window.open(url, '_blank', 'noopener,noreferrer')
    } catch {
      toast({
        variant: 'destructive',
        description: t('attachments.open_failed', "No s'ha pogut obrir l'arxiu"),
      })
    }
  }

  if (isLoading) {
    return <p className="text-sm text-muted-foreground">{t('attachments.loading', 'Carregant…')}</p>
  }
  if (attachments.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('attachments.empty', 'Cap arxiu adjunt')}
      </p>
    )
  }

  return (
    <ul className="space-y-1.5">
      {attachments.map((node) => {
        const kind = attachmentKind(node)
        const size = formatBytes(node.size_bytes)
        const openable = canOpenAttachment(node)
        return (
          <li
            key={node.id}
            className="flex items-center gap-2 rounded-lg border border-border px-3 py-2 text-sm"
          >
            <FileText className="h-4 w-4 shrink-0 text-muted-foreground" />
            <div className="min-w-0 flex-1">
              <p className="truncate font-medium">{node.name}</p>
              <p className="text-xs text-muted-foreground">
                {[kind, size].filter(Boolean).join(' · ')}
              </p>
            </div>
            {openable && (
              <Button
                type="button"
                size="sm"
                variant="outline"
                className="h-8 shrink-0 gap-1 px-2"
                onClick={() => void openNode(node)}
              >
                <ExternalLink className="h-3.5 w-3.5" />
                {t('closeout.open_file', 'Obrir')}
              </Button>
            )}
          </li>
        )
      })}
    </ul>
  )
}

export function CloseOutMaterialsPreview({ projectId }: { projectId: string }) {
  const { t } = useTranslation('field-service')
  const { data: materials = [], isLoading } = useQuery({
    queryKey: ['project_materials', projectId],
    queryFn: () => getProjectMaterials(projectId),
    enabled: !!projectId,
  })

  if (isLoading) {
    return <div className="h-12 animate-pulse rounded-lg bg-accent/40" />
  }
  if (materials.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('materials.empty', 'Cap material registrat')}
      </p>
    )
  }

  return (
    <ul className="space-y-2">
      {materials.map((item) => (
        <li
          key={item.id}
          className="flex items-center justify-between gap-2 rounded-lg border border-border px-3 py-2 text-sm"
        >
          <span className="min-w-0 truncate font-medium">{item.name}</span>
          <span className="shrink-0 text-muted-foreground">
            {item.quantity}
            {item.unit ? ` ${item.unit}` : ''}
          </span>
        </li>
      ))}
    </ul>
  )
}

function CloseOutTaskRow({ task }: { task: Task }) {
  const { t } = useTranslation('field-service')
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id
  const { data: photos = [] } = useQuery({
    queryKey: fieldMediaKeys.entity(tenantId ?? '', 'task', task.id ?? ''),
    queryFn: () =>
      listFieldMedia({
        tenantId: tenantId!,
        entityType: 'task',
        entityId: task.id!,
        purpose: 'task_evidence',
      }),
    enabled: !!tenantId && !!task.id,
  })
  const hasComment = htmlHasText(task.notes_html)

  return (
    <li className="space-y-2 rounded-lg border border-border px-3 py-2">
      <div className="flex items-start justify-between gap-2">
        <p className="text-sm font-medium">{task.title}</p>
        <span className="shrink-0 text-xs text-muted-foreground">
          {t(`resolution.task_status_${task.status ?? 'pending'}`, task.status ?? 'pending')}
        </span>
      </div>
      {hasComment ? (
        <div
          className="prose prose-sm dark:prose-invert max-w-none text-xs [&_a]:text-primary [&_a]:underline"
          dangerouslySetInnerHTML={{ __html: task.notes_html ?? '' }}
        />
      ) : (
        <p className="text-xs text-muted-foreground">
          {t('closeout.task_no_comment', 'Cap comentari')}
        </p>
      )}
      {tenantId && photos.length > 0 && (
        <FieldPhotoGallery photos={photos} tenantId={tenantId} size="sm" />
      )}
    </li>
  )
}

export function CloseOutTasksPreview({
  tasks,
  doneCount,
  openCount,
}: {
  tasks: Task[]
  doneCount: number
  openCount: number
}) {
  const { t } = useTranslation('field-service')

  if (tasks.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('closeout.tasks_empty', 'Cap tasca')}
      </p>
    )
  }

  return (
    <div className="space-y-2">
      <p className="text-xs text-muted-foreground">
        {doneCount}/{tasks.length}
        {openCount > 0 && (
          <span className="ml-1 text-destructive">
            ({t('closeout.tasks_open', '{{n}} obertes', { n: openCount })})
          </span>
        )}
      </p>
      <ul className="space-y-2">
        {tasks.map((task) => (
          <CloseOutTaskRow key={task.id} task={task} />
        ))}
      </ul>
    </div>
  )
}
