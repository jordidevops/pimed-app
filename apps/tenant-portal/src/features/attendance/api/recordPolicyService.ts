import { supabase } from '@/lib/supabase'
import type {
  CalendarGroupRecordPolicyResponse,
  ResolvedRecordPolicy,
} from './recordPolicyTypes'
import { parseRecordPolicy } from './recordPolicyTypes'

export async function getAttendanceRecordPolicy(
  employeeId: string,
  workDate?: string,
): Promise<ResolvedRecordPolicy> {
  const { data, error } = await supabase.rpc('get_attendance_record_policy', {
    p_employee_id: employeeId,
    p_work_date: workDate ?? new Date().toISOString().slice(0, 10),
  })
  if (error) throw error
  const row = data as Record<string, unknown>
  return {
    policy_id: (row.policy_id as string | null) ?? null,
    resolved_from: String(row.resolved_from ?? 'system_default'),
    work_profile: String(row.work_profile ?? 'fixed_site') as ResolvedRecordPolicy['work_profile'],
    policy_version: Number(row.policy_version ?? 2),
    policy: parseRecordPolicy(row.policy),
  }
}

export async function getCalendarGroupRecordPolicy(
  groupId: string,
  siteId?: string | null,
): Promise<CalendarGroupRecordPolicyResponse> {
  const { data, error } = await supabase.rpc('get_calendar_group_record_policy', {
    p_group_id: groupId,
    p_work_date: new Date().toISOString().slice(0, 10),
    p_site_id: siteId ?? undefined,
  })
  if (error) throw error
  const row = data as Record<string, unknown>
  return {
    policy_id: (row.policy_id as string | null) ?? null,
    scope: String(row.scope ?? 'group'),
    site_id: (row.site_id as string | null) ?? null,
    effective_from: (row.effective_from as string | null) ?? null,
    effective_to: (row.effective_to as string | null) ?? null,
    is_default: row.is_default === true,
    policy: parseRecordPolicy(row.policy),
  }
}

export async function upsertCalendarGroupRecordPolicy(params: {
  groupId: string
  policy: unknown
  effectiveFrom?: string
  siteId?: string | null
  policyId?: string | null
}): Promise<{ policy_id: string; scope: string }> {
  const { data, error } = await supabase.rpc('upsert_calendar_group_record_policy', {
    p_group_id: params.groupId,
    p_policy: params.policy,
    p_effective_from: params.effectiveFrom ?? new Date().toISOString().slice(0, 10),
    p_site_id: params.siteId ?? undefined,
    p_policy_id: params.policyId ?? undefined,
  })
  if (error) throw error
  return data as { policy_id: string; scope: string }
}
