import { supabase } from '@/lib/supabase'
import type { Json } from '@/types/database.types'

export type LegalDocCode =
  | 'privacy_customers'
  | 'legal_notice'
  | 'portal_terms_customers'
  | 'cookie_notice'
  | 'privacy_website'
  | 'privacy_employees'
  | 'employee_portal_terms'
  | 'privacy_candidates'
  | 'dpa_platform'

export type LegalDocMode = 'template' | 'edited' | 'external_url'

export type TenantLegalProfile = {
  tenant_id: string
  legal_name: string | null
  trade_name: string | null
  nif: string | null
  registry_info: string | null
  privacy_email: string | null
  dpo_email: string | null
  dpo_name: string | null
  postal_address: string | null
  website_url: string | null
  retention_summary: string | null
  dpa_acknowledged_at?: string | null
  dpa_acknowledged_by?: string | null
}

export type TenantLegalDocumentRow = {
  id: string
  code: LegalDocCode
  mode: LegalDocMode
  external_url: string | null
  updated_at: string
}

export type LegalCenterPayload = {
  profile: TenantLegalProfile
  documents: TenantLegalDocumentRow[]
  incomplete: boolean
  disclaimer: string
  dpa_acknowledged?: boolean
  dpa_acknowledged_at?: string | null
  privacy_candidates_note?: string
}

export type ResolvedLegalDocument = {
  ok: boolean
  error?: string
  mode?: LegalDocMode
  code?: string
  locale?: string
  title?: string
  body_html?: string
  external_url?: string
  version_number?: number
  template_version?: number
  tenant_id?: string
  disclaimer?: boolean
}

export const LEGAL_DOC_CODES: LegalDocCode[] = [
  'privacy_customers',
  'legal_notice',
  'portal_terms_customers',
  'cookie_notice',
  'privacy_website',
  'privacy_employees',
  'employee_portal_terms',
  'privacy_candidates',
  'dpa_platform',
]

function parseLegalCenterPayload(data: unknown): LegalCenterPayload {
  const row = (data && typeof data === 'object' ? data : {}) as Record<string, unknown>
  const profile = (row.profile && typeof row.profile === 'object'
    ? row.profile
    : {}) as TenantLegalProfile
  const documents = Array.isArray(row.documents)
    ? (row.documents as TenantLegalDocumentRow[])
    : []
  return {
    profile,
    documents,
    incomplete: row.incomplete === true,
    disclaimer: typeof row.disclaimer === 'string' ? row.disclaimer : '',
    dpa_acknowledged: row.dpa_acknowledged === true,
    dpa_acknowledged_at:
      typeof row.dpa_acknowledged_at === 'string' ? row.dpa_acknowledged_at : null,
    privacy_candidates_note:
      typeof row.privacy_candidates_note === 'string' ? row.privacy_candidates_note : undefined,
  }
}

export async function getTenantLegalCenter(): Promise<LegalCenterPayload> {
  const { data, error } = await supabase.rpc('get_my_tenant_legal_center' as never)
  if (error) throw error
  return parseLegalCenterPayload(data)
}

export async function upsertTenantLegalProfile(
  fields: Partial<
    Omit<TenantLegalProfile, 'tenant_id' | 'dpa_acknowledged_at' | 'dpa_acknowledged_by'>
  >,
): Promise<LegalCenterPayload> {
  const { data, error } = await supabase.rpc('upsert_my_tenant_legal_profile' as never, {
    p_legal_name: fields.legal_name ?? undefined,
    p_trade_name: fields.trade_name ?? undefined,
    p_nif: fields.nif ?? undefined,
    p_registry_info: fields.registry_info ?? undefined,
    p_privacy_email: fields.privacy_email ?? undefined,
    p_dpo_email: fields.dpo_email ?? undefined,
    p_dpo_name: fields.dpo_name ?? undefined,
    p_postal_address: fields.postal_address ?? undefined,
    p_website_url: fields.website_url ?? undefined,
    p_retention_summary: fields.retention_summary ?? undefined,
  } as never)
  if (error) throw error
  return parseLegalCenterPayload(data)
}

export async function setTenantLegalDocumentMode(params: {
  code: LegalDocCode
  mode: LegalDocMode
  externalUrl?: string | null
}): Promise<LegalCenterPayload> {
  const { data, error } = await supabase.rpc('set_my_tenant_legal_document_mode' as never, {
    p_code: params.code,
    p_mode: params.mode,
    p_external_url: params.externalUrl ?? null,
  } as never)
  if (error) throw error
  return parseLegalCenterPayload(data)
}

export async function acknowledgeTenantPlatformDpa(): Promise<LegalCenterPayload> {
  const { data, error } = await supabase.rpc(
    'acknowledge_my_tenant_platform_dpa' as never,
  )
  if (error) throw error
  return parseLegalCenterPayload(data)
}

export async function previewTenantLegalDocument(
  code: LegalDocCode,
  locale: string,
): Promise<ResolvedLegalDocument> {
  const { data, error } = await supabase.rpc('preview_my_tenant_legal_document' as never, {
    p_code: code,
    p_locale: locale,
  } as never)
  if (error) throw error
  return (data && typeof data === 'object' ? data : { ok: false }) as ResolvedLegalDocument
}

export async function publishTenantLegalDocumentVersion(params: {
  code: LegalDocCode
  locale: string
  title: string
  bodyHtml: string
}): Promise<Json> {
  const { data, error } = await supabase.rpc(
    'publish_my_tenant_legal_document_version' as never,
    {
      p_code: params.code,
      p_locale: params.locale,
      p_title: params.title,
      p_body_html: params.bodyHtml,
    } as never,
  )
  if (error) throw error
  return data as Json
}

export type CustomerPortalRetentionStatus = {
  settings: {
    enabled: boolean
    version_retention_days: number
    draft_retention_days: number
    access_log_retention_months: number
    unknown_token_retention_days: number
    session_purge_grace_days: number
  }
  version_counts: {
    active: number
    access_blocked: number
    purge_eligible: number
  }
  last_run: {
    id: string
    job_kind: string
    status: string
    counts: Record<string, unknown> | null
    started_at: string
    finished_at: string | null
    error_message: string | null
  } | null
  modules: {
    recruitment_rights: string
    employee_self_service: string | null
    note: string
  }
}

export type CustomerPortalDsarAction = {
  id: string
  contact_id: string
  reason: string | null
  result: Record<string, unknown>
  requested_by: string | null
  created_at: string
  contact_display_name: string | null
}

export type CustomerPortalDsarResult = {
  ok: boolean
  action_id: string
  contact_id: string
  shares_revoked: number
  grants_revoked: number
  invitations_revoked: number
  share_sessions_revoked: number
  grant_sessions_revoked: number
  staff_sessions_revoked: number
  versions_blocked: number
  reason: string
}

export async function getCustomerPortalRetentionStatus(): Promise<CustomerPortalRetentionStatus> {
  const { data, error } = await supabase.rpc(
    'get_my_customer_portal_retention_status' as never,
  )
  if (error) throw error
  return data as CustomerPortalRetentionStatus
}

export async function listCustomerPortalDsarActions(
  limit = 10,
): Promise<CustomerPortalDsarAction[]> {
  const { data, error } = await supabase.rpc(
    'list_my_customer_portal_dsar_actions' as never,
    { p_limit: limit } as never,
  )
  if (error) throw error
  return Array.isArray(data) ? (data as CustomerPortalDsarAction[]) : []
}

export async function executeCustomerPortalDsarRevoke(params: {
  contactId: string
  reason?: string
  blockAccountVersions?: boolean
}): Promise<CustomerPortalDsarResult> {
  const { data, error } = await supabase.rpc(
    'execute_customer_portal_dsar_revoke' as never,
    {
      p_contact_id: params.contactId,
      p_reason: params.reason ?? null,
      p_block_account_versions: params.blockAccountVersions ?? false,
    } as never,
  )
  if (error) throw error
  return data as CustomerPortalDsarResult
}
