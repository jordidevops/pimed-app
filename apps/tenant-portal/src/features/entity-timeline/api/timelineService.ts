import { supabase } from '@/lib/supabase'
import type { Json } from '@/types/database.types'

export type EntityTimelineType = 'employee' | 'contact' | 'project' | 'document'

export interface TimelineActor {
  id: string
  full_name: string | null
  avatar_url?: string | null
  actor_type?: string
}

export interface MentionReadStatus {
  id: string
  full_name: string | null
  read_at: string | null
}

export interface TimelineAuditItem {
  kind: 'audit_event'
  id: string
  created_at: string
  action: string
  message_key: string
  message_vars: Record<string, unknown>
  payload: Record<string, unknown>
  is_background?: boolean
  actor: TimelineActor | null
}

export interface TimelineCommentItem {
  kind: 'comment'
  id: string
  created_at: string
  content: string | null
  attachments?: CommentAttachment[]
  is_task: boolean
  resolved_at: string | null
  due_date?: string | null
  replies_count: number
  deleted: boolean
  pinned_at?: string | null
  is_ai_context_note?: boolean
  author: TimelineActor | null
  mentions_read?: MentionReadStatus[]
}

export interface CommentAttachment {
  file_id: string
  name: string
  mime: string | null
  size_bytes: number | null
}

export interface CommentRevision {
  id: string
  user_id: string
  content_before: string
  edited_at: string
}

export type TimelineItem = TimelineAuditItem | TimelineCommentItem

export interface TimelinePage {
  has_more: boolean
  next_cursor: string | null
  next_cursor_id: string | null
  unread_since_last_visit: number
  schema_version: number
}

export interface TimelineResponse {
  items: TimelineItem[]
  page: TimelinePage
}

export interface EntityTimelineVisitSummary {
  last_seen_at: string | null
  total_new: number
  comments_new: number
  audit_events_new: number
  tasks_new: number
  tasks_resolved_new: number
  highlights: Array<{
    kind: string
    action?: string | null
    message_vars?: Record<string, unknown>
    content?: string | null
    is_task?: boolean
    resolved_at?: string | null
    actor_name?: string | null
    created_at?: string
  }>
  schema_version?: number
}

export interface MentionMember {
  id: string
  full_name: string
  avatar_url: string | null
}

export interface GetTimelineParams {
  entityType: EntityTimelineType
  entityId: string
  limit?: number
  cursor?: string | null
  cursorId?: string | null
  includeAudit?: boolean
  tasksOnly?: boolean
  openTasksOnly?: boolean
  dateFrom?: string | null
  dateTo?: string | null
  search?: string | null
  includeBackground?: boolean
}

export async function getEntityTimeline(params: GetTimelineParams): Promise<TimelineResponse> {
  const { data, error } = await supabase.rpc('get_entity_timeline', {
    p_entity_type: params.entityType,
    p_entity_id: params.entityId,
    p_limit: params.limit ?? 30,
    p_cursor: params.cursor ?? undefined,
    p_cursor_id: params.cursorId ?? undefined,
    p_include_audit: params.includeAudit ?? true,
    p_tasks_only: params.tasksOnly ?? false,
    p_open_tasks_only: params.openTasksOnly ?? false,
    p_date_from: params.dateFrom ?? undefined,
    p_date_to: params.dateTo ?? undefined,
    p_search: params.search?.trim() || undefined,
    p_include_background: params.includeBackground ?? false,
  })

  if (error) throw error
  if (!data || typeof data !== 'object') {
    throw new Error('get_entity_timeline: resposta buida o invàlida')
  }
  return data as unknown as TimelineResponse
}

export async function getEntityTimelineVisitSummary(
  entityType: EntityTimelineType,
  entityId: string,
): Promise<EntityTimelineVisitSummary> {
  const { data, error } = await supabase.rpc('get_entity_timeline_visit_summary', {
    p_entity_type: entityType,
    p_entity_id: entityId,
  })
  if (error) throw error
  if (!data || typeof data !== 'object') {
    throw new Error('get_entity_timeline_visit_summary: resposta buida o invàlida')
  }
  return data as unknown as EntityTimelineVisitSummary
}

export async function markEntityTimelineSeen(
  entityType: EntityTimelineType,
  entityId: string,
): Promise<void> {
  const { error } = await supabase.rpc('mark_entity_timeline_seen', {
    p_entity_type: entityType,
    p_entity_id: entityId,
  })
  if (error) throw error
}

export async function insertEntityComment(params: {
  entityType: EntityTimelineType
  entityId: string
  content: string
  parentId?: string | null
  isTask?: boolean
  dueDate?: string | null
  isAiContextNote?: boolean
  siteId?: string | null
  attachments?: CommentAttachment[]
}): Promise<string> {
  const { data, error } = await supabase.rpc('insert_entity_comment', {
    p_entity_type: params.entityType,
    p_entity_id: params.entityId,
    p_content: params.content,
    p_parent_id: params.parentId ?? undefined,
    p_is_task: params.isTask ?? false,
    p_site_id: params.siteId ?? undefined,
    p_attachments: (params.attachments ?? []) as unknown as Json,
    p_due_date: params.dueDate ? dueDateInputToIso(params.dueDate) : undefined,
    p_is_ai_context_note: params.isAiContextNote ?? false,
  })
  if (error) throw error
  return data as string
}

export async function updateEntityComment(params: {
  commentId: string
  content: string
  isTask?: boolean
  dueDate?: string | null
}): Promise<void> {
  const clearDue = params.isTask === false || params.dueDate === ''
  const { error } = await supabase.rpc('update_entity_comment', {
    p_id: params.commentId,
    p_content: params.content,
    p_is_task: params.isTask,
    p_due_date: params.dueDate && params.dueDate.length > 0
      ? dueDateInputToIso(params.dueDate)
      : undefined,
    p_clear_due: clearDue,
  })
  if (error) throw error
}

/** Converteix timestamptz ISO a valor vàlid per <input type="date"> (timezone local). */
export function toDueDateInputValue(value: string | null | undefined): string {
  if (!value) return ''
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return ''
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

/** Data del formulari (YYYY-MM-DD) → timestamptz migdia local. */
export function dueDateInputToIso(dateStr: string): string {
  const [y, m, d] = dateStr.split('-').map(Number)
  const local = new Date(y, m - 1, d, 12, 0, 0, 0)
  return local.toISOString()
}

export interface OpenTaskItem {
  id: string
  entity_type: EntityTimelineType
  entity_id: string
  entity_label: string
  deep_link: string
  content_preview: string
  created_at: string
  due_date: string | null
  is_overdue: boolean
  author: TimelineActor | null
}

export interface OpenTasksPage {
  has_more: boolean
  next_cursor: string | null
  next_cursor_id: string | null
  is_manager_view?: boolean
}

export interface OpenTasksResponse {
  items: OpenTaskItem[]
  page: OpenTasksPage
}

export interface TenantActivityItem {
  kind: 'comment' | 'audit_event'
  id: string
  created_at: string
  entity_type: EntityTimelineType
  entity_id: string
  entity_label: string
  deep_link: string
  content?: string | null
  is_task?: boolean
  resolved_at?: string | null
  deleted?: boolean
  author?: TimelineActor | null
  action?: string
  message_key?: string
  message_vars?: Record<string, unknown>
  is_background?: boolean
  actor?: TimelineActor | null
}

export interface TenantActivityPage {
  has_more: boolean
  next_cursor: string | null
  next_cursor_id: string | null
  since: string
  schema_version: number
}

export interface TenantActivityResponse {
  items: TenantActivityItem[]
  page: TenantActivityPage
}

export async function getTenantTimelineActivity(params?: {
  limit?: number
  cursor?: string | null
  cursorId?: string | null
  since?: string | null
  includeBackground?: boolean
  includeAudit?: boolean
}): Promise<TenantActivityResponse> {
  const { data, error } = await supabase.rpc('get_tenant_timeline_activity', {
    p_limit: params?.limit ?? 25,
    p_cursor: params?.cursor ?? undefined,
    p_cursor_id: params?.cursorId ?? undefined,
    p_since: params?.since ?? undefined,
    p_include_background: params?.includeBackground ?? false,
    p_include_audit: params?.includeAudit ?? true,
  })
  if (error) throw error
  if (!data || typeof data !== 'object') {
    throw new Error('get_tenant_timeline_activity: resposta buida o invàlida')
  }
  return data as unknown as TenantActivityResponse
}

export async function getMyOpenTasks(params?: {
  limit?: number
  cursor?: string | null
  cursorId?: string | null
}): Promise<OpenTasksResponse> {
  const { data, error } = await supabase.rpc('get_my_open_tasks', {
    p_limit: params?.limit ?? 10,
    p_cursor: params?.cursor ?? undefined,
    p_cursor_id: params?.cursorId ?? undefined,
  })
  if (error) throw error
  if (!data || typeof data !== 'object') {
    throw new Error('get_my_open_tasks: resposta buida o invàlida')
  }
  return data as unknown as OpenTasksResponse
}

export async function getEntityOpenTasks(
  entityType: EntityTimelineType,
  entityId: string,
  limit = 50,
): Promise<OpenTaskItem[]> {
  const { data, error } = await supabase.rpc('get_entity_open_tasks', {
    p_entity_type: entityType,
    p_entity_id: entityId,
    p_limit: limit,
  })
  if (error) throw error
  const payload = data as { items?: OpenTaskItem[] } | null
  return payload?.items ?? []
}

export async function pinEntityComment(commentId: string, pinned = true): Promise<void> {
  const { error } = await supabase.rpc('pin_entity_comment', {
    p_id: commentId,
    p_pinned: pinned,
  })
  if (error) throw error
}

export async function deleteEntityComment(commentId: string): Promise<void> {
  const { error } = await supabase.rpc('delete_entity_comment', { p_id: commentId })
  if (error) throw error
}

export async function resolveEntityCommentTask(
  commentId: string,
  resolved = true,
): Promise<void> {
  const { error } = await supabase.rpc('resolve_entity_comment_task', {
    p_id: commentId,
    p_resolved: resolved,
  })
  if (error) throw error
}

export async function markEntityCommentMentionRead(commentId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc('mark_entity_comment_mention_read', {
    p_comment_id: commentId,
  })
  if (error) throw error
  return data === true
}

export async function searchMembersForMention(
  query: string,
  limit = 10,
): Promise<MentionMember[]> {
  const { data, error } = await supabase.rpc('search_tenant_members_for_mention', {
    p_query: query,
    p_limit: limit,
  })
  if (error) throw error
  return (data as unknown as MentionMember[]) ?? []
}

export async function getCommentReplies(commentId: string) {
  const { data, error } = await supabase.rpc('get_entity_comment_replies', {
    p_comment_id: commentId,
    p_limit: 50,
    p_offset: 0,
  })
  if (error) throw error
  return data as unknown as Array<{
    id: string
    created_at: string
    content: string | null
    deleted: boolean
    is_task: boolean
    resolved_at: string | null
    attachments?: CommentAttachment[]
    author: TimelineActor | null
  }>
}

export async function getCommentRevisions(commentId: string): Promise<CommentRevision[]> {
  const { data, error } = await supabase.rpc('get_entity_comment_revisions', {
    p_comment_id: commentId,
  })
  if (error) throw error
  return (data as unknown as CommentRevision[]) ?? []
}

export interface CommentTemplate {
  id: string
  entity_type: EntityTimelineType | null
  title: string
  body: string
  default_is_task: boolean
  sort_order: number
}

export async function listCommentTemplates(
  entityType?: EntityTimelineType | null,
): Promise<CommentTemplate[]> {
  const { data, error } = await supabase.rpc('list_entity_comment_templates', {
    p_entity_type: entityType ?? undefined,
  })
  if (error) throw error
  return (data as unknown as CommentTemplate[]) ?? []
}

export async function upsertCommentTemplate(input: {
  id?: string | null
  title: string
  body: string
  entity_type?: EntityTimelineType | null
  default_is_task?: boolean
  sort_order?: number
}): Promise<string> {
  const { data, error } = await supabase.rpc('upsert_entity_comment_template', {
    p_id: input.id ?? undefined,
    p_title: input.title,
    p_body: input.body,
    p_entity_type: input.entity_type ?? undefined,
    p_default_is_task: input.default_is_task ?? false,
    p_sort_order: input.sort_order ?? 0,
  })
  if (error) throw error
  return data as string
}

export async function deleteCommentTemplate(id: string): Promise<void> {
  const { error } = await supabase.rpc('delete_entity_comment_template', { p_id: id })
  if (error) throw error
}

export async function getEntitySubscriptionStatus(
  entityType: EntityTimelineType,
  entityId: string,
): Promise<boolean> {
  const { data, error } = await supabase.rpc('get_entity_subscription_status', {
    p_entity_type: entityType,
    p_entity_id: entityId,
  })
  if (error) throw error
  return Boolean(data)
}

export async function setEntitySubscription(
  entityType: EntityTimelineType,
  entityId: string,
  subscribed: boolean,
): Promise<boolean> {
  const { data, error } = await supabase.rpc('set_entity_subscription', {
    p_entity_type: entityType,
    p_entity_id: entityId,
    p_subscribed: subscribed,
  })
  if (error) throw error
  return Boolean(data)
}
