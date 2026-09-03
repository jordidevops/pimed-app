import { useEffect, useMemo } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useTranslation } from 'react-i18next'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useAuth } from '@/contexts/AuthContext'
import { useMembers } from '@/hooks/useMembers'
import { useCreateTask } from '../api/useCreateTask'
import { useUpdateTask } from '../api/useUpdateTask'
import type { Task } from '../api/tasksService'
import { getTaskCalendarContext, toDateInputValue } from '../api/tasksService'
import type { ReminderInput } from '@/features/calendar/calendar.form.types'
import { REMINDER_PRESETS } from '@/features/calendar/calendar.form.validation'

const taskSchema = z.object({
  title: z.string().min(1, 'validation.title_required'),
  status: z.string().optional(),
  due_date: z.string().optional().or(z.literal('')),
  assignee_id: z.string().optional().or(z.literal('')),
  add_reminder: z.boolean().optional(),
  reminder_offset: z.string().optional(),
})

type TaskFormValues = z.infer<typeof taskSchema>

interface TaskFormProps {
  open: boolean
  onClose: () => void
  projectId: string
  editTask?: Task | null
}

export function TaskForm({ open, onClose, projectId, editTask }: TaskFormProps) {
  const { t } = useTranslation(['projects', 'calendar'])
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const { user } = useAuth()
  const isEditing = !!editTask

  const { data: members = [] } = useMembers(activeTenant?.id ?? null, user?.id)
  const assigneeOptions = useMemo(() => {
    const seen = new Set<string>()
    return members.filter((m) => {
      if (!m.is_active || seen.has(m.user_id)) return false
      seen.add(m.user_id)
      return true
    })
  }, [members])

  const createMutation = useCreateTask(projectId)
  const updateMutation = useUpdateTask(projectId)

  const {
    register,
    handleSubmit,
    reset,
    watch,
    formState: { errors, isSubmitting },
  } = useForm<TaskFormValues>({
    resolver: zodResolver(taskSchema),
    defaultValues: {
      title: '',
      status: 'pending',
      due_date: '',
      assignee_id: '',
      add_reminder: false,
      reminder_offset: '30',
    },
  })

  const dueDate = watch('due_date')
  const hasReminder = watch('add_reminder')

  useEffect(() => {
    if (!open) return

    if (!editTask) {
      reset({
        title: '',
        status: 'pending',
        due_date: '',
        assignee_id: '',
        add_reminder: false,
        reminder_offset: '30',
      })
      return
    }

    let cancelled = false

    void (async () => {
      let reminderOffset: number | null = null
      if (activeTenant?.id && editTask.id) {
        try {
          const ctx = await getTaskCalendarContext(editTask.id, activeTenant.id)
          reminderOffset = ctx.reminderOffsetMinutes
        } catch {
          // best-effort
        }
      }

      if (cancelled) return

      reset({
        title: editTask.title ?? '',
        status: editTask.status ?? 'pending',
        due_date: toDateInputValue(editTask.due_date),
        assignee_id: editTask.assignee_id ?? '',
        add_reminder: reminderOffset != null,
        reminder_offset: String(reminderOffset ?? 30),
      })
    })()

    return () => {
      cancelled = true
    }
  }, [open, editTask, activeTenant?.id, reset])

  async function onSubmit(values: TaskFormValues) {
    if (!activeTenant?.id) return

    try {
      const reminders: ReminderInput[] = []
      if (values.due_date && values.add_reminder && values.reminder_offset) {
        reminders.push({
          offset_minutes: parseInt(values.reminder_offset, 10),
          channel: 'email',
        })
      }

      if (isEditing) {
        await updateMutation.mutateAsync({
          id: editTask!.id!,
          params: {
            tenant_id: activeTenant.id,
            title: values.title,
            status: values.status ?? null,
            due_date: values.due_date || null,
            assignee_id: values.assignee_id || null,
            reminders,
          },
        })
        toast({ description: t('projects:projects.tasks.toast_updated', 'Tasca actualitzada') })
      } else {
        await createMutation.mutateAsync({
          tenant_id: activeTenant.id,
          project_id: projectId,
          title: values.title,
          status: values.status,
          due_date: values.due_date || null,
          assignee_id: values.assignee_id || null,
          reminders,
        })
        toast({ description: t('projects:projects.tasks.toast_created', 'Tasca creada') })
      }
      onClose()
    } catch {
      toast({
        variant: 'destructive',
        description: isEditing
          ? t('projects:projects.tasks.error_update', 'Error en actualitzar la tasca')
          : t('projects:projects.tasks.error_create', 'Error en crear la tasca'),
      })
    }
  }

  const title = isEditing
    ? t('projects.tasks.form_title_edit', 'Editar tasca')
    : t('projects.tasks.form_title_new', 'Nova tasca')

  return (
    <Dialog open={open} onOpenChange={(v) => { if (!v) onClose() }}>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4 mt-2">
          {/* Title */}
          <div className="space-y-1">
            <label className="text-sm font-medium" htmlFor="task-title">
              {t('projects.tasks.title', 'Títol')}
              <span className="text-destructive ml-1">*</span>
            </label>
            <Input
              id="task-title"
              placeholder={t('projects.tasks.title_placeholder', 'Descripció de la tasca')}
              {...register('title')}
              aria-invalid={!!errors.title}
            />
            {errors.title && (
              <p className="text-xs text-destructive">
                {t('projects.tasks.error_title_required', 'El títol és obligatori')}
              </p>
            )}
          </div>

          {/* Status */}
          <div className="space-y-1">
            <label className="text-sm font-medium" htmlFor="task-status">
              {t('projects.tasks.status', 'Estat')}
            </label>
            <select
              id="task-status"
              {...register('status')}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
            >
              <option value="pending">{t('projects.tasks.status_pending', 'Pendent')}</option>
              <option value="in_progress">{t('projects.tasks.status_in_progress', 'En curs')}</option>
              <option value="done">{t('projects.tasks.status_done', 'Fet')}</option>
              <option value="blocked">{t('projects.tasks.status_blocked', 'Bloquejat')}</option>
            </select>
          </div>

          {/* Assignee */}
          <div className="space-y-1">
            <label className="text-sm font-medium" htmlFor="task-assignee">
              {t('projects:projects.tasks.assignee', 'Assignat a')}
            </label>
            <select
              id="task-assignee"
              {...register('assignee_id')}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
            >
              <option value="">
                {t('projects:projects.tasks.assignee_none', '— Sense assignar —')}
              </option>
              {assigneeOptions.map((member) => (
                <option key={member.user_id} value={member.user_id}>
                  {member.full_name?.trim() || member.email}
                </option>
              ))}
            </select>
          </div>

          {/* Due date */}
          <div className="space-y-1">
            <label className="text-sm font-medium" htmlFor="task-due">
              {t('projects:projects.tasks.due_date', 'Data límit')}
            </label>
            <Input id="task-due" type="date" {...register('due_date')} />
          </div>

          {/* Reminders section (only if due_date is set) */}
          {dueDate && (
            <div className="space-y-2 border-t pt-3">
              <div className="flex items-center gap-2">
                <input
                  type="checkbox"
                  id="task-add-reminder"
                  {...register('add_reminder')}
                  className="h-4 w-4 rounded border-input"
                />
                <label htmlFor="task-add-reminder" className="text-sm font-medium">
                  {t('calendar:calendar.reminders.addReminder', 'Afegir recordatori')}
                </label>
              </div>

              {hasReminder && (
                <div className="pl-6">
                  <label className="text-sm font-medium" htmlFor="task-reminder-offset">
                    {t('calendar:calendar.reminders.offsetLabel', 'Recordar')}
                  </label>
                  <select
                    id="task-reminder-offset"
                    {...register('reminder_offset')}
                    className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm mt-1"
                  >
                    {REMINDER_PRESETS.map((preset) => (
                      <option key={preset.value} value={preset.value}>
                        {preset.label}
                      </option>
                    ))}
                  </select>
                </div>
              )}
            </div>
          )}

          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="outline" onClick={onClose}>
              {t('projects.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting
                ? t('projects.form.saving', 'Desant…')
                : t('projects.form.save', 'Desar')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
