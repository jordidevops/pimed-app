import type { QueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export type FieldVisitMember = {
  user_id: string
  display_name: string
  role: string
}

export type FieldVisit = {
  id: string
  type: string
  name: string
  status: string
  planned_start: string | null
  planned_end: string | null
  client_display_name: string | null
  contact_site_name: string | null
  contact_site_city: string | null
  service_mode: string | null
  commercial_regime: string | null
  members: FieldVisitMember[]
}

export type ListFieldVisitsParams = {
  tenantId: string
  from?: string | null
  to?: string | null
  types?: string[]
  memberIds?: string[] | null
  statuses?: string[] | null
  openOnly?: boolean
  unscheduled?: boolean
  limit?: number
}

function parseMembers(raw: unknown): FieldVisitMember[] {
  if (!Array.isArray(raw)) return []
  return raw
    .map((item) => {
      if (!item || typeof item !== 'object') return null
      const row = item as Record<string, unknown>
      const userId = typeof row.user_id === 'string' ? row.user_id : null
      if (!userId) return null
      return {
        user_id: userId,
        display_name: typeof row.display_name === 'string' ? row.display_name : userId,
        role: typeof row.role === 'string' ? row.role : 'contributor',
      }
    })
    .filter((m): m is FieldVisitMember => Boolean(m))
}

export async function listFieldVisits(params: ListFieldVisitsParams): Promise<FieldVisit[]> {
  const { data, error } = await supabase.rpc('list_field_visits', {
    p_tenant_id: params.tenantId,
    p_from: params.from ?? undefined,
    p_to: params.to ?? undefined,
    p_types: params.types ?? ['work_order', 'maintenance'],
    p_member_ids: params.memberIds?.length ? params.memberIds : undefined,
    p_statuses: params.statuses?.length ? params.statuses : undefined,
    p_open_only: params.openOnly ?? true,
    p_unscheduled: params.unscheduled ?? false,
    p_limit: params.limit ?? 500,
  })

  if (error) throw error

  return (data ?? []).map((row) => ({
    id: row.id,
    type: row.type,
    name: row.name,
    status: row.status,
    planned_start: row.planned_start,
    planned_end: row.planned_end,
    client_display_name: row.client_display_name,
    contact_site_name: row.contact_site_name,
    contact_site_city: row.contact_site_city,
    service_mode: row.service_mode,
    commercial_regime: row.commercial_regime,
    members: parseMembers(row.members),
  }))
}

export const fieldVisitsKeys = {
  all: (tenantId: string | null | undefined) => ['field-service', 'field-visits', tenantId] as const,
  list: (tenantId: string | null | undefined, filters: Record<string, unknown>) =>
    [...fieldVisitsKeys.all(tenantId), filters] as const,
}

/** Invalidate agenda / today caches after project mutations. */
export function invalidateFieldVisitQueries(
  queryClient: QueryClient,
  tenantId?: string | null,
) {
  void queryClient.invalidateQueries({ queryKey: fieldVisitsKeys.all(tenantId) })
  void queryClient.invalidateQueries({ queryKey: ['field-service', 'field-visits'] })
  void queryClient.invalidateQueries({ queryKey: ['field-service', 'today-orders'] })
  void queryClient.invalidateQueries({ queryKey: ['field-service', 'agenda-orders'] })
}
