import { supabase } from '@/lib/supabase'

/** RPCs F3 encara no reflectits a database.types — crida tipada manualment. */
const rpc = supabase.rpc.bind(supabase) as (
  fn: string,
  args?: Record<string, unknown>,
) => ReturnType<typeof supabase.rpc>

export const TIMELINE_WEBHOOK_EVENTS = [
  { code: 'timeline.comment.created', labelKey: 'webhooks.events.comment_created' },
  { code: 'timeline.mention.created', labelKey: 'webhooks.events.mention_created' },
  { code: 'timeline.task.resolved', labelKey: 'webhooks.events.task_resolved' },
] as const

export const TIMELINE_ENTITY_TYPES = [
  'employee',
  'contact',
  'project',
  'document',
] as const

export type TimelineWebhookEvent = (typeof TIMELINE_WEBHOOK_EVENTS)[number]['code']
export type TimelineEntityType = (typeof TIMELINE_ENTITY_TYPES)[number]

export interface TenantWebhook {
  id: string
  label: string
  endpoint_url: string
  events: TimelineWebhookEvent[]
  entity_types: TimelineEntityType[] | null
  is_active: boolean
  secret_hint: string
  created_at: string
  updated_at: string
}

export interface WebhookDeliveryLogEntry {
  id: string
  webhook_id: string
  event_type: string
  status: 'pending' | 'delivered' | 'failed'
  attempts: number
  response_status: number | null
  error_message: string | null
  created_at: string
  last_attempt_at: string | null
}

export interface UpsertWebhookInput {
  id?: string
  label: string
  endpoint_url: string
  events: TimelineWebhookEvent[]
  entity_types: TimelineEntityType[] | null
  is_active: boolean
  rotate_secret?: boolean
}

export interface UpsertWebhookResult extends TenantWebhook {
  secret?: string | null
}

export async function fetchTenantWebhooks(): Promise<TenantWebhook[]> {
  const { data, error } = await rpc('list_tenant_webhooks')
  if (error) throw error
  return (data ?? []) as unknown as TenantWebhook[]
}

export async function upsertTenantWebhook(
  input: UpsertWebhookInput,
): Promise<UpsertWebhookResult> {
  const { data, error } = await rpc('upsert_tenant_webhook', {
    p_id: input.id ?? null,
    p_label: input.label,
    p_endpoint_url: input.endpoint_url,
    p_events: input.events,
    p_entity_types: input.entity_types?.length ? input.entity_types : null,
    p_is_active: input.is_active,
    p_rotate_secret: input.rotate_secret ?? false,
  })
  if (error) throw error
  return data as unknown as UpsertWebhookResult
}

export async function deleteTenantWebhook(id: string): Promise<void> {
  const { error } = await rpc('delete_tenant_webhook', { p_id: id })
  if (error) throw error
}

export async function testTenantWebhook(id: string): Promise<string> {
  const { data, error } = await rpc('test_tenant_webhook', { p_webhook_id: id })
  if (error) throw error
  return String(data)
}

export async function fetchWebhookDeliveryLog(
  webhookId?: string,
  limit = 20,
): Promise<WebhookDeliveryLogEntry[]> {
  const { data, error } = await rpc('list_webhook_delivery_log', {
    p_webhook_id: webhookId ?? null,
    p_limit: limit,
  })
  if (error) throw error
  return (data ?? []) as unknown as WebhookDeliveryLogEntry[]
}
