import { supabase } from '@/lib/supabase'
import i18n from '@/locales/i18n'
import { humanizeMentionTokens } from '@/features/entity-timeline/utils/mentionFormat'

export interface InAppNotification {
  id: string
  tenant_id: string
  kind: string
  severity: string | null
  title_i18n: Record<string, string> | null
  body_i18n: Record<string, string> | null
  deep_link: string | null
  related_entity_type: string | null
  related_entity_id: string | null
  read_at: string | null
  created_at: string
}

function pickI18n(value: Record<string, string> | null | undefined, fallback = ''): string {
  if (!value) return fallback
  const lang = i18n.language?.split('-')[0] ?? 'ca'
  return value[lang] ?? value.ca ?? value.en ?? Object.values(value)[0] ?? fallback
}

export function formatNotificationTitle(n: InAppNotification): string {
  return pickI18n(n.title_i18n, n.kind)
}

export function formatNotificationBody(n: InAppNotification): string {
  return humanizeMentionTokens(pickI18n(n.body_i18n, ''))
}

export async function listMyNotifications(limit = 25): Promise<InAppNotification[]> {
  const { data, error } = await supabase
    .from('notifications')
    .select('*')
    .order('created_at', { ascending: false })
    .limit(limit)

  if (error) throw error
  return (data ?? []) as InAppNotification[]
}

export async function countUnreadNotifications(): Promise<number> {
  const { count, error } = await supabase
    .from('notifications')
    .select('id', { count: 'exact', head: true })
    .is('read_at', null)

  if (error) throw error
  return count ?? 0
}

export async function markNotificationRead(notificationId: string): Promise<void> {
  const { error } = await supabase.rpc('mark_notification_read', { p_id: notificationId })
  if (error) throw error
}

export async function markAllNotificationsRead(): Promise<void> {
  const { data, error } = await supabase
    .from('notifications')
    .select('id')
    .is('read_at', null)
    .limit(100)

  if (error) throw error
  await Promise.all(
    (data ?? [])
      .map((row) => row.id)
      .filter((id): id is string => typeof id === 'string' && id.length > 0)
      .map((id) => markNotificationRead(id)),
  )
}
