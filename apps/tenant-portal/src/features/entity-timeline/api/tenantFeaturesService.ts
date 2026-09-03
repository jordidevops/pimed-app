import { supabase } from '@/lib/supabase'

export type TenantTimelineFeatures = {
  entity_timeline_risk_detector: boolean
  entity_timeline_playbooks: boolean
  entity_timeline_webhooks: boolean
  entity_timeline_export: boolean
  entity_timeline_manager_feed: boolean
  recruitment_enabled: boolean
}

export const tenantFeaturesKeys = {
  all: ['tenant-features'] as const,
  tenant: (tenantId: string) => [...tenantFeaturesKeys.all, tenantId] as const,
}

export async function fetchTenantTimelineFeatures(): Promise<TenantTimelineFeatures> {
  const { data, error } = await supabase.rpc('get_tenant_features')

  // Race on first paint: active_tenant_id() can briefly be unread → 42501.
  // Prefer empty features over throwing (timeline gates stay off).
  if (error) {
    if (error.code === '42501' || /forbidden/i.test(error.message)) {
      return {
        entity_timeline_risk_detector: false,
        entity_timeline_playbooks: false,
        entity_timeline_webhooks: false,
        entity_timeline_export: false,
        entity_timeline_manager_feed: false,
        recruitment_enabled: false,
      }
    }
    throw error
  }

  const raw = (typeof data === 'string' ? JSON.parse(data) : data ?? {}) as Record<
    string,
    boolean | null | undefined
  >

  return {
    entity_timeline_risk_detector: Boolean(raw.entity_timeline_risk_detector),
    entity_timeline_playbooks: Boolean(raw.entity_timeline_playbooks),
    entity_timeline_webhooks: Boolean(raw.entity_timeline_webhooks),
    entity_timeline_export: Boolean(raw.entity_timeline_export),
    entity_timeline_manager_feed: Boolean(raw.entity_timeline_manager_feed),
    recruitment_enabled: Boolean(raw.recruitment_enabled),
  }
}
