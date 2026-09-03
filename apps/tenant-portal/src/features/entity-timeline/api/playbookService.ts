import { supabase } from '@/lib/supabase'

function asJsonbArray<T>(data: unknown): T[] {
  if (Array.isArray(data)) return data as T[]
  if (typeof data === 'string') {
    try {
      const parsed = JSON.parse(data)
      return Array.isArray(parsed) ? (parsed as T[]) : []
    } catch {
      return []
    }
  }
  return []
}

export interface AuditEventPlaybook {
  id: string
  action: string
  template_id: string
  template_title: string
  template_body: string
  sort_order: number
  is_active: boolean
}

export const PLAYBOOK_AUDIT_ACTIONS = [
  'EMPLOYEE_TERMINATED',
  'EMPLOYEE_CREATED',
  'EMPLOYEE_UPDATED',
  'CONTACT_ARCHIVED',
  'CONTACT_CREATED',
  'PROJECT_STATUS',
] as const

export type PlaybookAuditAction = (typeof PLAYBOOK_AUDIT_ACTIONS)[number]

export async function listAuditEventPlaybooks(): Promise<AuditEventPlaybook[]> {
  const { data, error } = await supabase.rpc('list_audit_event_playbooks')
  if (error) throw error
  return asJsonbArray<AuditEventPlaybook>(data)
}

export async function upsertAuditEventPlaybook(input: {
  id?: string
  action: string
  template_id: string
  sort_order?: number
  is_active?: boolean
}): Promise<string> {
  const { data, error } = await supabase.rpc('upsert_audit_event_playbook', {
    p_id: input.id ?? undefined,
    p_action: input.action,
    p_template_id: input.template_id,
    p_sort_order: input.sort_order ?? 0,
    p_is_active: input.is_active ?? true,
  })
  if (error) throw error
  return data as string
}

export async function deleteAuditEventPlaybook(id: string): Promise<void> {
  const { error } = await supabase.rpc('delete_audit_event_playbook', { p_id: id })
  if (error) throw error
}
