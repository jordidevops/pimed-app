import { supabase } from '@/lib/supabase'
import type { Json } from '@/types/database.types'
import type {
  ContentListFilters,
  PublishContentResult,
  TenantContentItem,
  UpsertContentResult,
} from './tenantContentTypes'

function parseItem(raw: unknown): TenantContentItem {
  return raw as TenantContentItem
}

export async function listTenantContentItems(
  tenantId: string,
  filters: ContentListFilters = {},
): Promise<TenantContentItem[]> {
  const { data, error } = await supabase.rpc('list_tenant_content_items', {
    p_tenant_id: tenantId,
    p_filters: filters,
  })
  if (error) throw error
  const result = data as { ok?: boolean; items?: unknown[] }
  if (!result?.ok) return []
  return (result.items ?? []).map(parseItem)
}

export async function getTenantContentItem(
  tenantId: string,
  itemId: string,
): Promise<TenantContentItem | null> {
  const { data, error } = await supabase.rpc('get_tenant_content_item', {
    p_tenant_id: tenantId,
    p_item_id: itemId,
  })
  if (error) throw error
  const result = data as { ok?: boolean; item?: unknown }
  if (!result?.ok || !result.item) return null
  return parseItem(result.item)
}

export async function upsertTenantContentItem(
  tenantId: string,
  payload: Record<string, unknown>,
): Promise<UpsertContentResult> {
  const { data, error } = await supabase.rpc('upsert_tenant_content_item', {
    p_tenant_id: tenantId,
    p_payload: payload as Json,
  })
  if (error) throw error
  return data as UpsertContentResult
}

export async function publishTenantContentItem(
  tenantId: string,
  itemId: string,
): Promise<PublishContentResult> {
  const { data, error } = await supabase.rpc('publish_tenant_content_item', {
    p_tenant_id: tenantId,
    p_item_id: itemId,
  })
  if (error) throw error
  return data as PublishContentResult
}

export async function archiveTenantContentItem(
  tenantId: string,
  itemId: string,
): Promise<UpsertContentResult> {
  const { data, error } = await supabase.rpc('archive_tenant_content_item', {
    p_tenant_id: tenantId,
    p_item_id: itemId,
  })
  if (error) throw error
  return data as UpsertContentResult
}

export async function getTenantContentUsage(tenantId: string) {
  const { data, error } = await supabase.rpc('get_tenant_content_usage', {
    p_tenant_id: tenantId,
  })
  if (error) throw error
  return data as {
    ok: boolean
    entitlements?: unknown
    usage?: {
      content_items_total: number
      content_items_employee_channel: number
      content_items_public_channel: number
    }
  }
}

export async function previewTenantContentReach(tenantId: string, itemId: string) {
  const { data, error } = await supabase.rpc('preview_tenant_content_reach', {
    p_tenant_id: tenantId,
    p_item_id: itemId,
  })
  if (error) throw error
  return data as { ok: boolean; employee_count?: number; code?: string }
}

export async function listPublicSitesForTenant(tenantId: string) {
  const { data, error } = await supabase
    .from('public_sites')
    .select('id, slug, name, status, supported_locales, default_locale')
    .eq('tenant_id', tenantId)
    .order('created_at', { ascending: true })
  if (error) throw error
  return data ?? []
}
