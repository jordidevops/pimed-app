import { useState, useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { Plus, Pencil, Trash2, CheckSquare } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTasks } from '../api/useTasks'
import { useDeleteTask } from '../api/useDeleteTask'
import { useBulkUpdateTaskStatus } from '../api/useBulkUpdateTaskStatus'
import { useCreateTask } from '../api/useCreateTask'
import { TaskForm } from './TaskForm'
import { useTenant } from '@/contexts/TenantContext'
import { useAuth } from '@/contexts/AuthContext'
import { useMembers } from '@/hooks/useMembers'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { FieldTaskCard } from '@/features/field-service/components/FieldTaskCard'
import type { Task } from '../api/tasksService'

// Tasks created by the pre-versioned checklist engine; hidden from the work task list.
const LEGACY_CHECKLIST_TAGS = ['[fs-checklist]', '[migrated-checklist]']

interface TaskListProps {
  projectId: string
  readOnly?: boolean
}

const STATUS_VARIANT: Record<string, 'default' | 'secondary' | 'destructive' | 'outline'> = {
  pending: 'outline',
  in_progress: 'default',
  done: 'secondary',
  blocked: 'destructive',
}

const TASK_STATUSES = ['pending', 'in_progress', 'done', 'blocked'] as const

export function TaskList({ projectId, readOnly }: TaskListProps) {
  const { t } = useTranslation(['projects', 'field-service', 'common'])
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const { user } = useAuth()
  const isFieldService = useIsFieldService()
  const { data: members = [] } = useMembers(activeTenant?.id ?? null, user?.id)
  const memberByUserId = useMemo(
    () => new Map(members.map((m) => [m.user_id, m])),
    [members],
  )
  const { data: tasks = [], isLoading } = useTasks(projectId)
  const workTasks = useMemo(
    () => tasks.filter(
      (task) => !LEGACY_CHECKLIST_TAGS.some((tag) => task.title?.includes(tag)),
    ),
    [tasks],
  )
  const deleteMutation = useDeleteTask(projectId)
  const bulkMutation = useBulkUpdateTaskStatus(projectId)
  const createMutation = useCreateTask(projectId)

  const [formOpen, setFormOpen] = useState(false)
  const [editTarget, setEditTarget] = useState<Task | null>(null)
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [bulkStatus, setBulkStatus] = useState<string>('')
  const [creatingInline, setCreatingInline] = useState(false)
  const [newTitle, setNewTitle] = useState('')

  function handleOpenCreate() {
    if (isFieldService) {
      setCreatingInline(true)
      setNewTitle('')
      return
    }
    setEditTarget(null)
    setFormOpen(true)
  }

  function handleEdit(task: Task) {
    setEditTarget(task)
    setFormOpen(true)
  }

  async function handleDelete(task: Task) {
    try {
      await deleteMutation.mutateAsync(task.id!)
      setSelectedIds((prev) => { const s = new Set(prev); s.delete(task.id!); return s })
      toast({ description: t('projects.tasks.toast_deleted', 'Tasca eliminada') })
    } catch {
      toast({
        variant: 'destructive',
        description: t('projects.tasks.error_delete', 'Error en eliminar la tasca'),
      })
    }
  }

  async function handleCreateInline() {
    const title = newTitle.trim()
    if (!title || !activeTenant?.id) return
    try {
      await createMutation.mutateAsync({
        tenant_id: activeTenant.id,
        project_id: projectId,
        title,
        status: 'pending',
      })
      setNewTitle('')
      setCreatingInline(false)
      toast({ description: t('projects.tasks.toast_created', 'Tasca creada') })
    } catch {
      toast({
        variant: 'destructive',
        description: t('projects.tasks.error_create', 'Error en crear la tasca'),
      })
    }
  }

  function toggleSelect(id: string) {
    setSelectedIds((prev) => {
      const s = new Set(prev)
      if (s.has(id)) s.delete(id)
      else s.add(id)
      return s
    })
  }

  function toggleSelectAll() {
    if (selectedIds.size === workTasks.length) {
      setSelectedIds(new Set())
    } else {
      setSelectedIds(new Set(workTasks.map((t) => t.id!).filter(Boolean)))
    }
  }

  async function handleBulkApply() {
    if (!bulkStatus || selectedIds.size === 0 || !activeTenant) return
    try {
      const result = await bulkMutation.mutateAsync({
        taskIds: Array.from(selectedIds),
        newStatus: bulkStatus,
        tenantId: activeTenant.id,
      })
      setSelectedIds(new Set())
      setBulkStatus('')
      toast({
        description: t('projects.worklog.tasks_bulk_success', '{{count}} tasca actualitzada', {
          count: result.updatedCount,
        }),
      })
    } catch {
      toast({
        variant: 'destructive',
        description: t('projects.worklog.tasks_bulk_error', 'Error en actualitzar les tasques'),
      })
    }
  }

  const allSelected = workTasks.length > 0 && selectedIds.size === workTasks.length
  const someSelected = selectedIds.size > 0

  return (
    <div>
      <div className="flex items-center justify-between mb-3">
        <h2 className="font-semibold text-foreground flex items-center gap-2">
          <CheckSquare className="h-4 w-4 text-muted-foreground" />
          {t('projects.tasks.title_section', 'Tasques')}
          {workTasks.length > 0 && (
            <span className="text-xs font-normal text-muted-foreground">
              ({workTasks.filter((t) => t.status === 'done').length}/{workTasks.length})
            </span>
          )}
        </h2>
        {!readOnly && (
          <Button variant="outline" size="sm" className="gap-1.5 h-7 text-xs" onClick={handleOpenCreate}>
            <Plus className="h-3.5 w-3.5" />
            {t('projects.tasks.add', 'Afegir tasca')}
          </Button>
        )}
      </div>

      {isLoading ? (
        <div className="flex items-center justify-center py-8">
          <div className="h-5 w-5 animate-spin rounded-full border-2 border-primary border-t-transparent" />
        </div>
      ) : isFieldService ? (
        <ul className="space-y-3">
          {workTasks.length === 0 && !creatingInline && (
            <li className="text-sm text-muted-foreground text-center py-8">
              {t('projects.tasks.empty', 'Encara no hi ha tasques')}
            </li>
          )}
          {workTasks.map((task) => (
            <FieldTaskCard
              key={task.id}
              task={task}
              projectId={projectId}
              readOnly={readOnly}
            />
          ))}
          {creatingInline && (
            <li className="flex flex-col gap-2 rounded-lg border border-dashed border-border p-3 sm:flex-row sm:items-center">
              <Input
                autoFocus
                value={newTitle}
                onChange={(e) => setNewTitle(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') void handleCreateInline()
                  if (e.key === 'Escape') {
                    setCreatingInline(false)
                    setNewTitle('')
                  }
                }}
                placeholder={t('field-service:tasks.new_placeholder', 'Nom de la tasca…')}
                className="h-9 flex-1"
              />
              <div className="flex gap-2">
                <Button
                  size="sm"
                  className="h-9"
                  disabled={!newTitle.trim() || createMutation.isPending}
                  onClick={() => void handleCreateInline()}
                >
                  {t('projects.tasks.add', 'Afegir tasca')}
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  className="h-9"
                  onClick={() => {
                    setCreatingInline(false)
                    setNewTitle('')
                  }}
                >
                  {t('common:cancel', 'Cancel·lar')}
                </Button>
              </div>
            </li>
          )}
        </ul>
      ) : workTasks.length === 0 ? (
        <p className="text-sm text-muted-foreground text-center py-8">
          {t('projects.tasks.empty', 'Encara no hi ha tasques')}
        </p>
      ) : (
        <>
          {/* Capçalera amb "selecciona tot" */}
          <div className="flex items-center gap-2 mb-1.5 px-1">
            <input
              type="checkbox"
              aria-label={t('projects.tasks.select_all', 'Selecciona totes les tasques')}
              checked={allSelected}
              ref={(el) => { if (el) el.indeterminate = someSelected && !allSelected }}
              onChange={toggleSelectAll}
              className="h-3.5 w-3.5 rounded border-border accent-primary cursor-pointer"
            />
            <span className="text-xs text-muted-foreground">
              {someSelected
                ? t('projects.worklog.tasks_bulk_selected', '{{count}} seleccionada', { count: selectedIds.size })
                : t('projects.tasks.title_section', 'Tasques')
              }
            </span>
          </div>

          <ul className="space-y-1.5">
            {workTasks.map((task) => (
              <li
                key={task.id}
                className={`flex items-center justify-between rounded-lg border px-3 py-2 hover:bg-muted/30 transition-colors ${
                  selectedIds.has(task.id!) ? 'border-primary/50 bg-primary/5' : 'border-border'
                }`}
              >
                <div className="flex items-center gap-2.5 min-w-0">
                  <input
                    type="checkbox"
                    aria-label={t('projects.tasks.select_task', 'Selecciona {{title}}', { title: task.title })}
                    checked={selectedIds.has(task.id!)}
                    onChange={() => toggleSelect(task.id!)}
                    className="h-3.5 w-3.5 rounded border-border accent-primary cursor-pointer shrink-0"
                  />
                  <Badge
                    variant={STATUS_VARIANT[task.status ?? ''] ?? 'outline'}
                    className="text-xs shrink-0"
                  >
                    {t(`projects.tasks.status_${task.status ?? 'pending'}`, task.status ?? 'pending')}
                  </Badge>
                  {task.source_checklist_run_item_id && (
                    <Badge variant="secondary" className="text-[10px] font-normal shrink-0">
                      {t('projects.tasks.from_checklist', 'Checklist')}
                    </Badge>
                  )}
                  <span className="text-sm truncate">{task.title}</span>
                  {task.assignee_id && (
                    <span className="text-xs text-muted-foreground shrink-0" title={t('projects.tasks.assignee', 'Assignat a')}>
                      {memberByUserId.get(task.assignee_id)?.full_name?.trim()
                        || memberByUserId.get(task.assignee_id)?.email
                        || '…'}
                    </span>
                  )}
                  {task.due_date && (
                    <span className="text-xs text-muted-foreground shrink-0">
                      {new Date(task.due_date).toLocaleDateString('ca-ES')}
                    </span>
                  )}
                </div>
                <div className="flex items-center gap-1 shrink-0 ml-2">
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-6 w-6"
                    onClick={() => handleEdit(task)}
                    aria-label={t('projects.tasks.edit_aria', 'Editar tasca')}
                  >
                    <Pencil className="h-3 w-3" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-6 w-6 text-destructive hover:text-destructive"
                    onClick={() => handleDelete(task)}
                    aria-label={t('projects.tasks.delete_aria', 'Eliminar tasca')}
                  >
                    <Trash2 className="h-3 w-3" />
                  </Button>
                </div>
              </li>
            ))}
          </ul>

          {/* Action bar de bulk — visible quan hi ha selecció */}
          {someSelected && (
            <div className="flex items-center gap-2 mt-3 p-2 rounded-lg border border-primary/20 bg-primary/5">
              <select
                aria-label={t('projects.worklog.tasks_bulk_select_status', 'Selecciona estat…')}
                value={bulkStatus}
                onChange={(e) => setBulkStatus(e.target.value)}
                className="flex-1 text-xs rounded border border-border bg-background px-2 py-1.5 focus:outline-none focus:ring-1 focus:ring-primary"
              >
                <option value="">{t('projects.worklog.tasks_bulk_select_status', 'Selecciona estat…')}</option>
                {TASK_STATUSES.map((s) => (
                  <option key={s} value={s}>
                    {t(`projects.tasks.status_${s}`, s)}
                  </option>
                ))}
              </select>
              <Button
                size="sm"
                className="h-7 text-xs"
                disabled={!bulkStatus || bulkMutation.isPending || !activeTenant}
                onClick={handleBulkApply}
              >
                {t('projects.worklog.tasks_bulk_apply', 'Aplicar estat')}
              </Button>
            </div>
          )}
        </>
      )}

      {!isFieldService && (
        <TaskForm
          open={formOpen}
          onClose={() => { setFormOpen(false); setEditTarget(null) }}
          projectId={projectId}
          editTask={editTarget}
        />
      )}
    </div>
  )
}
