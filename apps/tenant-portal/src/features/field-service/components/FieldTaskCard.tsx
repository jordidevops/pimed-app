import { useEffect, useRef, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Camera, MessageSquare, Trash2 } from 'lucide-react'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { RichTextEditor } from '@/components/ui/RichTextEditor'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useUpdateTask } from '@/features/projects/api/useUpdateTask'
import { useDeleteTask } from '@/features/projects/api/useDeleteTask'
import type { Task } from '@/features/projects/api/tasksService'
import { useAutosaveHtml } from '@/hooks/useAutosaveHtml'
import {
  fieldMediaKeys,
  listFieldMedia,
} from '../api/fieldMediaService'
import { AutosaveStatus } from './AutosaveStatus'
import { ChecklistItemEvidence } from './ChecklistItemEvidence'

const TASK_STATUSES = ['pending', 'in_progress', 'done', 'blocked'] as const

const STATUS_PILL: Record<string, { idle: string; selected: string }> = {
  pending: {
    idle: 'border-border bg-background text-muted-foreground',
    selected: 'border-slate-500 bg-slate-100 text-slate-900 dark:bg-slate-800 dark:text-slate-50',
  },
  in_progress: {
    idle: 'border-border bg-background text-muted-foreground',
    selected: 'border-sky-600 bg-sky-100 text-sky-950 dark:border-sky-400 dark:bg-sky-900/50 dark:text-sky-50',
  },
  done: {
    idle: 'border-border bg-background text-muted-foreground',
    selected: 'border-emerald-600 bg-emerald-100 text-emerald-950 dark:border-emerald-400 dark:bg-emerald-900/40 dark:text-emerald-50',
  },
  blocked: {
    idle: 'border-border bg-background text-muted-foreground',
    selected: 'border-rose-600 bg-rose-100 text-rose-950 dark:border-rose-400 dark:bg-rose-900/40 dark:text-rose-50',
  },
}

function htmlHasText(html?: string | null) {
  return Boolean(
    html
      ?.replace(/<[^>]+>/g, '')
      .replace(/&nbsp;/gi, ' ')
      .trim(),
  )
}

interface FieldTaskCardProps {
  task: Task
  projectId: string
  readOnly?: boolean
}

export function FieldTaskCard({ task, projectId, readOnly }: FieldTaskCardProps) {
  const { t } = useTranslation(['projects', 'field-service'])
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const updateMutation = useUpdateTask(projectId)
  const deleteMutation = useDeleteTask(projectId)
  const [notesOpen, setNotesOpen] = useState(false)
  const [photosOpen, setPhotosOpen] = useState(false)

  const [title, setTitle] = useState(task.title ?? '')
  const lastSavedTitle = useRef(task.title ?? '')

  useEffect(() => {
    setTitle(task.title ?? '')
    lastSavedTitle.current = task.title ?? ''
  }, [task.id, task.title])

  async function patch(fields: {
    title?: string
    status?: string
    notes_html?: string | null
  }) {
    if (!activeTenant?.id || !task.id) return
    try {
      await updateMutation.mutateAsync({
        id: task.id,
        params: { tenant_id: activeTenant.id, ...fields },
      })
    } catch {
      toast({
        variant: 'destructive',
        description: t('projects.tasks.error_update', 'Error en actualitzar la tasca'),
      })
      throw new Error('update_failed')
    }
  }

  const {
    html: notesHtml,
    dirty: notesDirty,
    saving: savingNotes,
    handleChange: handleNotesChange,
    flush: flushNotes,
    onBlurFlush: onNotesBlur,
  } = useAutosaveHtml({
    initialValue: task.notes_html,
    enabled: !readOnly,
    onSave: async (next) => {
      await patch({ notes_html: next })
    },
  })

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

  async function saveTitle() {
    const next = title.trim()
    if (!next) {
      setTitle(lastSavedTitle.current)
      return
    }
    if (next === lastSavedTitle.current) return
    try {
      await patch({ title: next })
      lastSavedTitle.current = next
    } catch {
      setTitle(lastSavedTitle.current)
    }
  }

  async function setStatus(status: string) {
    if (status === (task.status ?? 'pending') || readOnly) return
    try {
      await patch({ status })
    } catch {
      /* toast already shown */
    }
  }

  async function handleDelete() {
    if (!task.id || readOnly) return
    try {
      await deleteMutation.mutateAsync(task.id)
      toast({ description: t('projects.tasks.toast_deleted', 'Tasca eliminada') })
    } catch {
      toast({
        variant: 'destructive',
        description: t('projects.tasks.error_delete', 'Error en eliminar la tasca'),
      })
    }
  }

  const status = task.status ?? 'pending'
  const findingNote = task.source_finding_note?.trim()
  const dispositionNote = task.source_disposition_note?.trim()
  const hasNotes = htmlHasText(notesHtml)
  const photoCount = photos.length

  return (
    <li className="space-y-3 rounded-lg border border-border bg-card p-3">
      <div className="flex items-start gap-2">
        <Input
          value={title}
          disabled={readOnly || updateMutation.isPending}
          onChange={(e) => setTitle(e.target.value)}
          onBlur={() => void saveTitle()}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault()
              ;(e.target as HTMLInputElement).blur()
            }
          }}
          className="h-9 flex-1 text-sm font-medium"
          aria-label={t('projects.tasks.title', 'Títol')}
        />
        {!readOnly && (
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="h-9 w-9 shrink-0 text-destructive hover:text-destructive"
            onClick={() => void handleDelete()}
            aria-label={t('projects.tasks.delete_aria', 'Eliminar tasca')}
          >
            <Trash2 className="h-3.5 w-3.5" />
          </Button>
        )}
      </div>

      <div className="flex flex-wrap gap-1.5">
        {TASK_STATUSES.map((s) => {
          const selected = status === s
          const tone = STATUS_PILL[s]
          return (
            <button
              key={s}
              type="button"
              disabled={readOnly || updateMutation.isPending}
              className={`rounded-md border px-2.5 py-1.5 text-xs font-medium transition-colors ${
                selected ? tone.selected : tone.idle
              }`}
              onClick={() => void setStatus(s)}
            >
              {t(`projects.tasks.status_${s}`, s)}
            </button>
          )
        })}
      </div>

      {(findingNote || dispositionNote) && (
        <div className="space-y-1.5 rounded-md border border-amber-200/80 bg-amber-50/50 p-2.5 text-xs dark:border-amber-900 dark:bg-amber-950/30">
          {findingNote && (
            <div>
              <p className="font-medium text-amber-900 dark:text-amber-100">
                {t('field-service:tasks.finding_note', 'Nota de la troballa')}
              </p>
              <p className="mt-0.5 whitespace-pre-wrap text-amber-950/90 dark:text-amber-50/90">
                {findingNote}
              </p>
            </div>
          )}
          {dispositionNote && (
            <div>
              <p className="font-medium text-amber-900 dark:text-amber-100">
                {t('field-service:tasks.disposition_note', 'Disposició')}
              </p>
              <p className="mt-0.5 whitespace-pre-wrap text-amber-950/90 dark:text-amber-50/90">
                {dispositionNote}
              </p>
            </div>
          )}
        </div>
      )}

      <div className="flex flex-wrap gap-2">
        <button
          type="button"
          aria-pressed={notesOpen}
          aria-label={
            notesOpen
              ? t('field-service:tasks.hide_notes', 'Amagar comentari')
              : t('field-service:tasks.show_notes', 'Mostrar comentari')
          }
          className={cn(
            'inline-flex h-9 items-center gap-1.5 rounded-md border px-2.5 transition-colors',
            notesOpen
              ? 'border-primary bg-primary text-primary-foreground'
              : hasNotes
                ? 'border-border bg-background text-foreground hover:bg-muted/50'
                : 'border-border bg-background text-muted-foreground hover:bg-muted/50 hover:text-foreground',
          )}
          onClick={() => setNotesOpen((v) => !v)}
        >
          <MessageSquare className="h-4 w-4" />
          {hasNotes && !notesOpen && (
            <span className="flex h-4 min-w-4 items-center justify-center rounded-full bg-sky-600 px-1 text-[10px] font-bold text-white dark:bg-sky-500">
              1
            </span>
          )}
        </button>
        {task.id && (
          <button
            type="button"
            aria-pressed={photosOpen}
            aria-label={
              photosOpen
                ? t('field-service:tasks.hide_photos', 'Amagar fotos')
                : t('field-service:tasks.show_photos', 'Mostrar fotos')
            }
            className={cn(
              'inline-flex h-9 items-center gap-1.5 rounded-md border px-2.5 transition-colors',
              photosOpen
                ? 'border-primary bg-primary text-primary-foreground'
                : photoCount > 0
                  ? 'border-border bg-background text-foreground hover:bg-muted/50'
                  : 'border-border bg-background text-muted-foreground hover:bg-muted/50 hover:text-foreground',
            )}
            onClick={() => setPhotosOpen((v) => !v)}
          >
            <Camera className="h-4 w-4" />
            {photoCount > 0 && !photosOpen && (
              <span className="flex h-4 min-w-4 items-center justify-center rounded-full bg-sky-600 px-1 text-[10px] font-bold text-white dark:bg-sky-500">
                {photoCount}
              </span>
            )}
          </button>
        )}
      </div>

      {notesOpen && (
        <div className="space-y-2">
          <div className="flex items-center justify-between gap-2">
            <p className="text-xs font-medium text-foreground">
              {t('field-service:tasks.notes', 'Comentari / notes')}
            </p>
            {!readOnly && (
              <AutosaveStatus
                dirty={notesDirty}
                saving={savingNotes}
                onSave={() => void flushNotes()}
              />
            )}
          </div>
          <RichTextEditor
            value={notesHtml}
            onChange={handleNotesChange}
            onBlur={onNotesBlur}
            disabled={readOnly}
            placeholder={t(
              'field-service:tasks.notes_placeholder',
              'Detall per al butlletí / albarà…',
            )}
            linkHint={t(
              'field-service:work_notes.link_hint',
              'Pots enllaçar Drive, YouTube, manuals o altres documents externs.',
            )}
          />
        </div>
      )}

      {photosOpen && task.id && (
        <ChecklistItemEvidence
          itemId={task.id}
          itemTitle={title || task.title || 'Tasca'}
          disabled={readOnly}
          projectId={projectId}
          entityType="task"
          purpose="task_evidence"
          emptyHint={t(
            'field-service:tasks.photos_empty',
            'Afegeix fotos de la feina per al butlletí.',
          )}
        />
      )}
    </li>
  )
}
