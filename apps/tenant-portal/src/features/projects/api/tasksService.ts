import { supabase } from '@/lib/supabase'
import type { Json } from '@/types/database.types'
import type { Database } from '@/types/database.types'
import type { ReminderInput } from '@/features/calendar/calendar.form.types'

export type Task = Database['api']['Views']['tasks']['Row']
export type TaskUpdate = Database['api']['Views']['tasks']['Update']

export interface CreateTaskParams {
  tenant_id: string
  project_id: string
  title: string
  status?: string
  due_date?: string | null
  assignee_id?: string | null
  site_id?: string | null
  position?: number | null
  /** Recordatoris a encuar si due_date es proporciona */
  reminders?: ReminderInput[]
}

export interface UpdateTaskParams extends TaskUpdate {
  tenant_id: string
  site_id?: string | null
  reminders?: ReminderInput[]
}

export interface TaskCalendarContext {
  eventId: string | null
  reminderOffsetMinutes: number | null
}

/** Converteix timestamptz ISO a valor vàlid per <input type="date"> (timezone local). */
export function toDateInputValue(value: string | null | undefined): string {
  if (!value) return ''
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return ''
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

/** Data límit des del formulari (YYYY-MM-DD) → timestamptz migdia local. */
function dueDateInputToIso(dateStr: string): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  const local = new Date(y, m - 1, d, 12, 0, 0, 0)
  return local.toISOString()
}

export async function getTaskCalendarContext(
  taskId: string,
  tenantId: string,
): Promise<TaskCalendarContext> {
  const { data, error } = await supabase
    .from('calendar_events')
    .select('id, metadata')
    .eq('entity_type', 'task')
    .eq('entity_id', taskId)
    .eq('tenant_id', tenantId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()

  if (error) throw error

  const meta = data?.metadata as { reminder_offset_minutes?: number } | null

  return {
    eventId: data?.id ?? null,
    reminderOffsetMinutes:
      typeof meta?.reminder_offset_minutes === 'number'
        ? meta.reminder_offset_minutes
        : null,
  }
}

async function syncTaskCalendarEvent(
  taskId: string,
  params: {
    tenant_id: string
    title: string
    due_date: string
    site_id?: string | null
    reminders?: ReminderInput[]
  },
): Promise<void> {
  const startAt = dueDateInputToIso(params.due_date)
  const reminderMeta =
    params.reminders && params.reminders.length > 0
      ? { reminder_offset_minutes: params.reminders[0].offset_minutes }
      : {}

  const ctx = await getTaskCalendarContext(taskId, params.tenant_id)

  if (ctx.eventId) {
    const updatePayload = {
      title: params.title,
      start_at: startAt,
      end_at: startAt,
      all_day: true,
      metadata: reminderMeta as Json,
    }

    const { error: updateErr } = await supabase
      .from('calendar_events')
      .update(updatePayload as never)
      .eq('id', ctx.eventId)

    if (updateErr) throw updateErr

    if (params.reminders && params.reminders.length > 0) {
      const { error: remErr } = await supabase.rpc('enqueue_calendar_event_reminders', {
        p_tenant_id: params.tenant_id,
        p_event_id: ctx.eventId,
        p_site_id: params.site_id ?? undefined,
        p_reminders: params.reminders.map((r) => ({
          offset_minutes: r.offset_minutes,
          channel: r.channel,
        })),
      })
      if (remErr) throw remErr
    }
    return
  }

  const { error: calendarError } = await supabase.rpc('create_calendar_event_with_reminders', {
    p_tenant_id: params.tenant_id,
    p_entity_type: 'task',
    p_entity_id: taskId,
    p_title: params.title,
    p_start_at: startAt,
    p_end_at: startAt,
    p_all_day: true,
    p_site_id: params.site_id ?? undefined,
    p_metadata: Object.keys(reminderMeta).length > 0 ? reminderMeta : undefined,
    p_reminders:
      params.reminders && params.reminders.length > 0
        ? params.reminders.map((r) => ({
            offset_minutes: r.offset_minutes,
            channel: r.channel,
          }))
        : [],
  })

  if (calendarError) throw calendarError
}

export async function getTasks(projectId: string): Promise<Task[]> {
  const { data, error } = await supabase
    .from('tasks')
    .select('*')
    .eq('project_id', projectId)
    .order('position', { ascending: true })

  if (error) throw error
  return data ?? []
}

export async function createTask(params: CreateTaskParams): Promise<Task> {
  const { reminders, site_id, ...taskFields } = params

  const insertPayload = {
    ...taskFields,
    due_date: taskFields.due_date ? dueDateInputToIso(taskFields.due_date) : null,
  }

  const { data: createdTask, error: taskError } = await supabase
    .from('tasks')
    .insert(insertPayload)
    .select()
    .single()

  if (taskError) throw taskError
  if (!createdTask.id) {
    throw new Error('Task created without id')
  }

  if (taskFields.due_date) {
    try {
      await syncTaskCalendarEvent(createdTask.id, {
        tenant_id: taskFields.tenant_id,
        title: taskFields.title,
        due_date: taskFields.due_date,
        site_id,
        reminders,
      })
    } catch (err) {
      console.error('Error creating calendar event for task:', err)
    }
  }

  return createdTask
}

export async function updateTask(id: string, params: UpdateTaskParams): Promise<void> {
  const { tenant_id, site_id, reminders, due_date, ...taskFields } = params

  const updatePayload: TaskUpdate = {
    ...taskFields,
    ...(due_date !== undefined
      ? { due_date: due_date ? dueDateInputToIso(due_date) : null }
      : {}),
  }

  const { error } = await supabase.from('tasks').update(updatePayload).eq('id', id)
  if (error) throw error

  if (due_date) {
    try {
      await syncTaskCalendarEvent(id, {
        tenant_id,
        title: (taskFields.title as string) ?? '',
        due_date,
        site_id,
        reminders,
      })
    } catch (err) {
      console.error('Error syncing calendar event for task:', err)
    }
  }
}

export async function deleteTask(id: string): Promise<void> {
  const { error } = await supabase.from('tasks').delete().eq('id', id)
  if (error) throw error
}

export interface BulkUpdateTaskStatusResult {
  updatedCount: number
  skippedCount: number
}

export async function bulkUpdateTaskStatus(
  taskIds: string[],
  newStatus: string,
  tenantId: string,
): Promise<BulkUpdateTaskStatusResult> {
  if (taskIds.length === 0) return { updatedCount: 0, skippedCount: 0 }

  const { data, error } = await supabase.rpc('bulk_update_task_status', {
    p_task_ids: taskIds,
    p_new_status: newStatus,
    p_tenant_id: tenantId,
  })

  if (error) throw error

  const row = (data as { updated_count: number; skipped_count: number }[] | null)?.[0]
  return {
    updatedCount: row?.updated_count ?? 0,
    skippedCount: row?.skipped_count ?? 0,
  }
}
