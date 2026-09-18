import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

// ─── Types ────────────────────────────────────────────────────────────────────

export type DocumentTemplate      = Database['api']['Views']['document_templates']['Row']
export type DocumentTemplateLocale = Database['api']['Views']['document_template_locales']['Row']

export interface LocaleSummary {
  id:        string
  locale:    string
  is_active: boolean
}

export interface DocumentTemplateWithLocales extends DocumentTemplate {
  locales: LocaleSummary[]
}
// TenantSigningStatus inclou els camps de la vista tenant_signing_status
// més feature_enabled i can_activate retornats per la RPC api.get_signing_status.
export interface TenantSigningStatus {
  tenant_id:           string
  mode:                'platform' | 'byo'
  signing_credits:     number
  docuseal_api_url:    string | null
  is_active:           boolean
  admin_disabled:      boolean
  effective_is_active: boolean
  feature_enabled:     boolean
  can_activate:        boolean
}
export type SigningSubmission      = Database['api']['Views']['signing_submissions']['Row']
export type SigningEvent           = Database['api']['Views']['signing_events']['Row']

export type SigningProvider = 'docuseal' | 'native'

/** Fins que es regenerin els tipus després de la migració 20260615000008 */
export type SigningSubmissionExtended = SigningSubmission & {
  signing_provider?: SigningProvider | null
  native_group_id?:   string | null
}

export function getSigningProvider(
  sub: { signing_provider?: string | null } | null | undefined,
): SigningProvider {
  const p = sub?.signing_provider
  return p === 'native' ? 'native' : 'docuseal'
}

export type SigningStatus =
  | 'draft' | 'pending' | 'in_progress' | 'completed'
  | 'declined' | 'expired' | 'cancelled' | 'error'

export type NotificationMode =
  | 'docuseal_auto' | 'app_manual' | 'app_auto_all' | 'app_auto_sequential'

export interface SignerSnapshot {
  email:   string
  name:    string
  role?:   string
  status?: string
  completed_at?: string | null
  opened_at?: string | null
  signing_url?: string | null
  /** signer_order 0-indexed. Extret del external_id (:sN sufix) per DocuSeal. */
  order?: number
}

export type VariableType = 'string' | 'date' | 'number'
export interface VariableDef {
  type:      VariableType
  label?:    string
  required?: boolean
  role?:     string | null
  order?:    number
}
export type VariablesSchema = Record<string, VariableDef>

export interface SigningRoleDef {
  entity_type:             'employee' | 'contact' | 'user' | 'person' | 'site' | 'asset' | 'tenant' | 'catalog_item'
  label:                   string
  order:                   number
  for_signing:             boolean
  auto_assign_current_user?: boolean
}
export type SigningRolesSchema = Record<string, SigningRoleDef>

export type DocumentTemplateLocaleDetail =
  Database['api']['Views']['document_template_locale_detail']['Row']

const FUNCTIONS_BASE = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1`

const SESSION_EXPIRED_MESSAGE = 'Sessió expirada. Torna a iniciar sessió.'

/** Desperta el worker PGMQ (en local el cron pot trigar fins a 1 min). Fire-and-forget. */
export async function kickPdfQueueWorker(): Promise<void> {
  try {
    const accessToken = await getValidatedAccessToken()
    await fetch(`${FUNCTIONS_BASE}/process-document-pdf-queue`, {
      method:  'POST',
      headers: { Authorization: `Bearer ${accessToken}` },
    })
  } catch {
    // No bloquejar la UI si el kick falla; el cron ho recollirà.
  }
}

/** Valida el JWT amb el servidor (no només la caché local) abans de cridar Edge Functions. */
async function getValidatedAccessToken(): Promise<string> {
  const { data: { user }, error } = await supabase.auth.getUser()
  if (error || !user) {
    await supabase.auth.signOut()
    throw new Error(SESSION_EXPIRED_MESSAGE)
  }
  const { data: { session } } = await supabase.auth.getSession()
  if (!session?.access_token) {
    await supabase.auth.signOut()
    throw new Error(SESSION_EXPIRED_MESSAGE)
  }
  return session.access_token
}

// ─── Edge function call ────────────────────────────────────────────────────────

export interface SignDocumentInput {
  tenant_id:                   string
  action:                      'sign' | 'generate_only' | 'sign_native'
  source_type:                 'document_existing' | 'template_locale'
  source_document_version_id?: string
  source_template_locale_id?:  string
  folder_id?:                  string
  document_title?:             string
  document_category?:          string | null
  signer_email?:               string
  signer_name?:                string
  signer_role?:                string
  signers?:                    { email: string; name: string; role?: string; order?: number }[]
  /** Contracte canònic de context nested (globals els genera el servidor). */
  context?:                    Record<string, unknown>
  /** Binding de rols/prefixos a entitats concretes per resolució server-side de variables path-based.
   *  Clau = nom del rol (e.g. "Treballador") o prefix directe (e.g. "site").
   *  El servidor resol {{Treballador.full_name}} → employee.full_name sense heurística. */
  context_refs?:               Record<string, { entity_type: string; entity_id: string }>
  notification_mode?:          NotificationMode
  client_request_id?:          string
  output_format?:              'native' | 'pdf'
  output_profile?:             'pdf' | 'pdfa2b' | 'pdfa3b'
  native_sign_type?:           'presential' | 'remote'
  use_explicit_fields?:        boolean
}

export interface SignDocumentResult {
  action:                  string
  output_format?:          'native' | 'pdf'
  submission_id?:          string
  docuseal_submission_id?: string
  signing_url?:            string | null
  status?:                 string
  idempotent_replay?:      boolean
  document_id?:            string
  job_id?:                 string
  pdf_job_id?:             string
  session_id?:             string
  signing_type?:           string
  /** PDF generat síncronament: versió llesta per signar (no cal polling) */
  document_version_id?:    string
  /** Firma remota: si l'email s'ha encuat correctament */
  email_queued?:           boolean
  email_error?:            string
  signer_links?:           Array<{ order: number; email: string; role: string; signing_url: string | null }>
  notification_mode?:      NotificationMode
  document?:               { id?: string }
}

export function extractDocumentIdFromSignResult(
  res: SignDocumentResult | Record<string, unknown> | null | undefined,
): string | null {
  if (!res) return null
  const record = res as Record<string, unknown>
  if (typeof record.document_id === 'string' && record.document_id) {
    return record.document_id
  }
  const doc = record.document
  if (doc && typeof doc === 'object' && typeof (doc as { id?: string }).id === 'string') {
    return (doc as { id: string }).id
  }
  return null
}

export function extractDocumentVersionIdFromSignResult(
  res: SignDocumentResult | Record<string, unknown> | null | undefined,
): string | null {
  if (!res) return null
  const record = res as Record<string, unknown>
  if (typeof record.document_version_id === 'string' && record.document_version_id) {
    return record.document_version_id
  }
  const version = record.version
  if (version && typeof version === 'object' && typeof (version as { id?: string }).id === 'string') {
    return (version as { id: string }).id
  }
  return null
}

export type SigningSessionAction = 'check' | 'cancel_local' | 'cancel_and_delete_remote' | 'generate_native_audit'

export interface SigningSessionManagerInput {
  tenant_id: string
  submission_id: string
  action: SigningSessionAction
}

export interface SigningSessionManagerResult {
  action: SigningSessionAction
  submission_id: string
  tenant_id: string
  local_status: string
  docuseal_submission_id: string | null
  remote_found?: boolean
  remote_deleted?: boolean
  remote_submission?: Record<string, unknown> | null
  audit_storage_path?: string | null
  audit_job_id?: string | null
  message: string
}

export async function callSignDocumentRouter(
  input: SignDocumentInput,
): Promise<SignDocumentResult> {
  const accessToken = await getValidatedAccessToken()

  const idempotencyKey = input.client_request_id ?? crypto.randomUUID()

  const res = await fetch(`${FUNCTIONS_BASE}/sign-document-router`, {
    method:  'POST',
    headers: {
      'Content-Type':  'application/json',
      Authorization:   `Bearer ${accessToken}`,
      'x-tenant-id':   input.tenant_id,
      'Idempotency-Key': idempotencyKey,
    },
    body: JSON.stringify({ ...input, client_request_id: idempotencyKey }),
  })

  const json = await res.json().catch(() => null)
  if (!res.ok) {
    const message = json?.error?.message ?? json?.message ?? `HTTP ${res.status}`
    throw new Error(message)
  }
  return json as SignDocumentResult
}

export interface StampPdfSignaturesInput {
  session_id: string
  client_signature_base64: string
  operator_signature_base64?: string | null
}

export interface StampPdfSignaturesResult {
  success?: boolean
  result_version_id?: string
  audit_job_id?: string | null
  document_hash_before?: string
  document_hash_after?: string
}

export async function callStampPdfSignatures(
  input: StampPdfSignaturesInput,
  tenantId?: string,
): Promise<StampPdfSignaturesResult> {
  const accessToken = await getValidatedAccessToken()

  const res = await fetch(`${FUNCTIONS_BASE}/stamp-pdf-signatures`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${accessToken}`,
      ...(tenantId ? { 'x-tenant-id': tenantId } : {}),
    },
    body: JSON.stringify(input),
  })

  const json = await res.json().catch(() => null)
  if (!res.ok) {
    const message = json?.error?.message ?? json?.error ?? json?.message ?? `HTTP ${res.status}`
    throw new Error(typeof message === 'string' ? message : `HTTP ${res.status}`)
  }
  return json as StampPdfSignaturesResult
}

// ─── Auditoria native (hashes per submission) ─────────────────────────────────

export interface SignatureAuditRecord {
  session_id:           string
  signer_name:          string | null
  signer_email:         string | null
  signer_role:          string | null
  signer_order:         number | null
  timestamp_signed:     string | null
  document_hash_before: string | null
  document_hash_after:  string | null
  audit_pdf_path:       string | null
}

export async function fetchSignatureAuditForSubmission(
  submissionId: string,
): Promise<SignatureAuditRecord[]> {
  const { data, error } = await supabase.rpc(
    'get_signature_audit_for_submission' as never,
    { p_submission_id: submissionId } as never,
  )
  if (error) throw new Error(error.message)
  if (!data || !Array.isArray(data)) return []
  return data as SignatureAuditRecord[]
}

export async function callSigningSessionManager(
  input: SigningSessionManagerInput,
): Promise<SigningSessionManagerResult> {
  const accessToken = await getValidatedAccessToken()

  const res = await fetch(`${FUNCTIONS_BASE}/signing-session-manager`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${accessToken}`,
      'x-tenant-id': input.tenant_id,
    },
    body: JSON.stringify(input),
  })

  const json = await res.json().catch(() => null)
  if (!res.ok) {
    const message = json?.error?.message ?? json?.message ?? `HTTP ${res.status}`
    throw new Error(message)
  }
  return json as SigningSessionManagerResult
}

// ─── Template locale upload ────────────────────────────────────────────────────

// ─── Locale detail (carrega html_content per editor/preparació) ─────────────

export async function fetchLocaleDetail(
  localeId: string,
): Promise<DocumentTemplateLocaleDetail | null> {
  const { data, error } = await supabase
    .schema('api')
    .from('document_template_locale_detail')
    .select('*')
    .eq('id', localeId)
    .single()
  if (error) throw new Error(error.message)
  return data as DocumentTemplateLocaleDetail | null
}

const TEMPLATES_BUCKET = 'document-templates'

export async function uploadTemplateLocaleFile(
  tenantId:   string,
  templateId: string,
  locale:     string,
  file:       File,
): Promise<string> {
  const ext  = file.name.split('.').pop()?.toLowerCase() ?? 'docx'
  const path = `${tenantId}/${templateId}/${locale}.${ext}`

  const { error } = await supabase.storage
    .from(TEMPLATES_BUCKET)
    .upload(path, file, { contentType: file.type, upsert: true })

  if (error) throw new Error(error.message)
  return path
}
