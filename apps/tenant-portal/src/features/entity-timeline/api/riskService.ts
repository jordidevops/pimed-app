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

export type RiskRuleType =
  | 'task_overdue'
  | 'unread_mention'
  | 'pending_signature'
  | 'employee_status_churn'
  | 'stale_thread'

export interface EntityRiskRule {
  id: string
  rule_type: RiskRuleType
  threshold_value: number
  threshold_unit: 'days' | 'hours' | 'count'
  action_type: 'notify' | 'notify_and_escalate'
  scan_cadence: 'daily' | 'weekly' | 'realtime'
  is_active: boolean
}

export interface EntityRiskAlert {
  kind: 'unread_mention' | 'status_churn'
  comment_id?: string
  mention_id?: string
  mention_name?: string
  created_at?: string
  content_preview?: string
  incident_id?: string
  detected_at?: string
  change_count?: number
  message?: string
}

export async function listEntityRiskRules(): Promise<EntityRiskRule[]> {
  const { data, error } = await supabase.rpc('list_entity_risk_rules')
  if (error) throw error
  return asJsonbArray<EntityRiskRule>(data)
}

export async function upsertEntityRiskRule(input: {
  id?: string
  rule_type?: RiskRuleType
  threshold_value?: number
  is_active?: boolean
}): Promise<string> {
  const { data, error } = await supabase.rpc('upsert_entity_risk_rule', {
    p_id: input.id ?? undefined,
    p_rule_type: input.rule_type ?? undefined,
    p_threshold_value: input.threshold_value ?? undefined,
    p_is_active: input.is_active ?? undefined,
  })
  if (error) throw error
  return data as string
}

export async function getEntityRiskAlerts(
  entityType: string,
  entityId: string,
): Promise<EntityRiskAlert[]> {
  const { data, error } = await supabase.rpc('get_entity_risk_alerts', {
    p_entity_type: entityType,
    p_entity_id: entityId,
  })
  if (error) throw error
  return asJsonbArray<EntityRiskAlert>(data)
}
