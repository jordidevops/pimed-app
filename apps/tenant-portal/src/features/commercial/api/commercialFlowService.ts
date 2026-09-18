import { supabase } from '@/lib/supabase'
import { generateClientOpId } from '@/features/attendance/api/clientOpId'
import type {
  CommercialAddressSnapshot,
  CommercialDocumentDetail,
  CommercialDocumentLine,
  CommercialPartySnapshot,
  CommercialTaxBreakdownRow,
} from '../utils/commercialDocumentModel'
import { remainingCentsForDocument } from '../utils/paymentAllocation'
import { getFunctionErrorMessage } from '@/lib/functionErrors'

export type PricingTemplate = {
  id: string
  tenant_id: string
  name: string
  description: string | null
  category: string | null
  is_active: boolean
  is_default: boolean
  created_at: string
  updated_at: string
}

export type PricingTemplateItem = {
  id: string
  template_id: string
  tenant_id: string
  catalog_item_id: string
  default_quantity: number
  prompt_quantity: boolean
  prompt_label: string | null
  default_discount_pct: number
  position: number
  catalog_item_name?: string | null
  catalog_item_unit?: string | null
  catalog_item_unit_price?: number | null
}

export type CommercialDocument = {
  id: string
  tenant_id: string
  doc_type: 'quote' | 'quote_amendment' | 'delivery_note'
  doc_number: string | null
  client_id: string
  project_id: string | null
  status: string
  seller_snapshot?: CommercialPartySnapshot
  buyer_snapshot?: CommercialPartySnapshot
  service_address_snapshot?: CommercialAddressSnapshot
  terms_text?: string | null
  locale?: string
  currency?: string
  subtotal: number
  tax_breakdown?: CommercialTaxBreakdownRow[]
  /** @deprecated Prefer tax_breakdown; kept for older UI reads */
  tax_total?: number
  total: number
  show_prices: boolean | null
  issued_at: string | null
  valid_until: string | null
  parent_document_id: string | null
  supersedes_id: string | null
  created_at: string
  external_invoice_ref?: string | null
  rendered_document_id?: string | null
  pdf_job_id?: string | null
  document_template_id?: string | null
}

export type { CommercialDocumentDetail, CommercialDocumentLine }

export type CommercialDocumentLinkInfo = Pick<
  CommercialDocument,
  'id' | 'doc_type' | 'doc_number' | 'project_id' | 'status'
>

export async function getCommercialDocumentLinkInfo(
  documentId: string,
): Promise<CommercialDocumentLinkInfo | null> {
  const { data, error } = await supabase
    .from('commercial_documents' as never)
    .select('id, doc_type, doc_number, project_id, status')
    .eq('id', documentId)
    .maybeSingle()
  if (error) throw error
  return (data as CommercialDocumentLinkInfo | null) ?? null
}

export function commercialDocumentOrderPath(
  projectBase: string,
  projectId: string,
  docType: CommercialDocument['doc_type'],
): string {
  const tab = docType === 'delivery_note' ? 'deliver' : 'prepare'
  return `${projectBase}/${projectId}?tab=${tab}`
}

export async function listPricingTemplates(): Promise<PricingTemplate[]> {
  const { data, error } = await supabase
    .from('pricing_templates' as never)
    .select('*')
    .eq('is_active', true)
    .order('name')
  if (error) throw error
  return (data ?? []) as PricingTemplate[]
}

export async function listPricingTemplateItems(
  templateId: string,
): Promise<PricingTemplateItem[]> {
  const { data, error } = await supabase
    .from('pricing_template_items' as never)
    .select('*')
    .eq('template_id', templateId)
    .order('position')
  if (error) throw error
  return (data ?? []) as PricingTemplateItem[]
}

export async function createPricingTemplate(params: {
  name: string
  description?: string | null
  category?: string | null
  isDefault?: boolean
}): Promise<string> {
  const { data, error } = await supabase.rpc('create_pricing_template' as never, {
    p_name: params.name,
    p_description: params.description ?? null,
    p_category: params.category ?? null,
    p_is_default: params.isDefault ?? false,
  } as never)
  if (error) throw error
  return data as string
}

export async function updatePricingTemplate(params: {
  id: string
  name: string
  description?: string | null
  category?: string | null
  isDefault?: boolean
  isActive?: boolean
}): Promise<void> {
  const { error } = await supabase.rpc('update_pricing_template' as never, {
    p_id: params.id,
    p_name: params.name,
    p_description: params.description ?? null,
    p_category: params.category ?? null,
    p_is_default: params.isDefault ?? false,
    p_is_active: params.isActive ?? true,
  } as never)
  if (error) throw error
}

export async function deactivatePricingTemplate(id: string): Promise<void> {
  const { error } = await supabase.rpc('deactivate_pricing_template' as never, {
    p_id: id,
  } as never)
  if (error) throw error
}

export type PricingTemplateItemInput = {
  catalog_item_id: string
  default_quantity: number
  prompt_quantity: boolean
  prompt_label?: string | null
  default_discount_pct?: number
  position: number
}

export async function savePricingTemplateItems(
  templateId: string,
  items: PricingTemplateItemInput[],
): Promise<void> {
  const { error } = await supabase.rpc('save_pricing_template_items' as never, {
    p_template_id: templateId,
    p_items: items,
  } as never)
  if (error) throw error
}

/** Apply template; quantities keyed by pricing_template_items.id */
export async function applyPricingTemplate(params: {
  projectId: string
  templateId: string
  quantities: Record<string, number>
  discountPct?: number | null
  clientOpId?: string
}): Promise<{
  status: string
  line_ids?: string[]
  application_id?: string
  checklist_run_ids?: string[]
}> {
  const clientOpId = params.clientOpId ?? generateClientOpId()
  const { data, error } = await supabase.rpc('apply_pricing_template' as never, {
    p_project_id: params.projectId,
    p_template_id: params.templateId,
    p_quantities: params.quantities,
    p_discount_pct: params.discountPct ?? null,
    p_client_op_id: clientOpId,
  } as never)
  if (error) throw new Error(error.message)
  return (data ?? { status: 'unknown' }) as {
    status: string
    line_ids?: string[]
    application_id?: string
    checklist_run_ids?: string[]
  }
}

export type PricingJobSearchRow = {
  id: string
  name: string
  status: string
  client_id: string | null
  client_display_name: string
  site_id: string | null
  updated_at: string
  created_at: string
  line_count: number
  subtotal: number
  same_client: boolean
  service_mode?: string | null
  commercial_regime?: string | null
}

export type PriceSheetSkippedLine = {
  name?: string
  reason?: string
  detail?: string
}

export type PriceSheetWriteResult = {
  status: string
  mode?: string
  copied?: number
  inserted?: number
  line_ids?: string[]
  skipped?: PriceSheetSkippedLine[]
  checklist_run_ids?: string[]
  quote_warning?: { quote_issued?: boolean; message?: string }
}

export type CreatePackFromProjectResult = {
  template_id: string
  item_count: number
  skipped?: PriceSheetSkippedLine[]
  created_catalog_ids?: string[]
  checklist_template_ids?: string[]
}

export async function searchJobsForPricing(params: {
  query?: string
  clientId?: string | null
  excludeProjectId: string
  completedOnly?: boolean
  limit?: number
}): Promise<PricingJobSearchRow[]> {
  const { data, error } = await supabase.rpc('search_jobs_for_pricing', {
    p_query: params.query || undefined,
    p_client_id: params.clientId || undefined,
    p_exclude_project_id: params.excludeProjectId,
    p_completed_only: params.completedOnly ?? false,
    p_limit: params.limit ?? 30,
  })
  if (error) throw new Error(error.message)
  return (data ?? []) as PricingJobSearchRow[]
}

export async function copyProjectLines(params: {
  sourceProjectId: string
  targetProjectId: string
  mode: 'append' | 'replace'
  clientOpId?: string
}): Promise<PriceSheetWriteResult> {
  const { data, error } = await supabase.rpc('copy_project_lines', {
    p_source_project_id: params.sourceProjectId,
    p_target_project_id: params.targetProjectId,
    p_mode: params.mode,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  })
  if (error) throw new Error(error.message)
  return (data ?? { status: 'unknown' }) as PriceSheetWriteResult
}

export async function createPricingTemplateFromProject(params: {
  projectId: string
  name: string
  category?: string | null
  unmatchedMode?: 'skip' | 'create_catalog'
}): Promise<CreatePackFromProjectResult> {
  const { data, error } = await supabase.rpc('create_pricing_template_from_project', {
    p_project_id: params.projectId,
    p_name: params.name,
    p_category: params.category ?? undefined,
    p_unmatched_mode: params.unmatchedMode ?? 'skip',
  })
  if (error) throw new Error(error.message)
  return data as CreatePackFromProjectResult
}

export type PriceSheetLineInput = {
  catalog_item_id?: string | null
  kind?: string
  name?: string
  description?: string | null
  unit?: string
  quantity: number
  unit_price?: number
  discount_pct?: number
  tax_rate?: number
}

export async function applyPriceSheet(params: {
  projectId: string
  lines: PriceSheetLineInput[]
  mode: 'append' | 'replace'
  checklistTemplateId?: string | null
  clientOpId?: string
}): Promise<PriceSheetWriteResult> {
  const { data, error } = await supabase.rpc('apply_price_sheet', {
    p_project_id: params.projectId,
    p_lines: params.lines,
    p_mode: params.mode,
    p_checklist_template_id: params.checklistTemplateId ?? undefined,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  })
  if (error) throw new Error(error.message)
  return (data ?? { status: 'unknown' }) as PriceSheetWriteResult
}

export async function listPricingTemplateChecklists(
  templateId: string,
): Promise<{ checklist_template_id: string; position: number }[]> {
  const { data, error } = await supabase
    .from('pricing_template_checklists' as never)
    .select('checklist_template_id, position')
    .eq('template_id', templateId)
    .order('position')
  if (error) throw error
  return (data ?? []) as { checklist_template_id: string; position: number }[]
}

export async function savePricingTemplateChecklists(
  templateId: string,
  checklistTemplateIds: string[],
): Promise<void> {
  const { error } = await supabase.rpc('save_pricing_template_checklists' as never, {
    p_template_id: templateId,
    p_checklist_template_ids: checklistTemplateIds,
  } as never)
  if (error) throw error
}

export async function issueCommercialDocument(params: {
  projectId: string
  docType: 'quote' | 'quote_amendment' | 'delivery_note'
  showPrices?: boolean
  parentDocumentId?: string | null
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('issue_commercial_document' as never, {
    p_project_id: params.projectId,
    p_doc_type: params.docType,
    p_show_prices: params.showPrices ?? true,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
    p_parent_document_id: params.parentDocumentId ?? null,
  } as never)
  if (error) throw error
  return data as string
}

export async function reissueCommercialQuote(params: {
  previousDocumentId: string
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc(
    'reissue_commercial_quote' as never,
    {
      p_previous_document_id: params.previousDocumentId,
      p_client_op_id: params.clientOpId ?? generateClientOpId(),
    } as never,
  )
  if (error) throw error
  return data as string
}

export async function acceptCommercialDocument(params: {
  documentId: string
  signature: Record<string, unknown>
  clientOpId?: string
}): Promise<unknown> {
  const { data, error } = await supabase.rpc('accept_commercial_document' as never, {
    p_document_id: params.documentId,
    p_signature: params.signature,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
  return data
}

export async function rejectCommercialDocument(params: {
  documentId: string
  signature: Record<string, unknown>
  reason?: string | null
  clientOpId?: string
}): Promise<unknown> {
  const { data, error } = await supabase.rpc('reject_commercial_document' as never, {
    p_document_id: params.documentId,
    p_signature: {
      ...params.signature,
      ...(params.reason != null ? { reason: params.reason } : {}),
    },
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
  return data
}

export async function signCommercialDeliveryNote(params: {
  documentId: string
  signature: Record<string, unknown>
  clientOpId?: string
}): Promise<unknown> {
  const { data, error } = await supabase.rpc('sign_commercial_delivery_note' as never, {
    p_document_id: params.documentId,
    p_signature: params.signature,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
  return data
}

export async function registerCommercialSigningIntent(params: {
  documentId: string
  sessionId: string
  action: 'accept' | 'reject' | 'delivery'
  clientOpId: string
  submissionId?: string | null
}): Promise<string> {
  const { data, error } = await supabase.rpc('register_commercial_signing_intent' as never, {
    p_document_id: params.documentId,
    p_session_id: params.sessionId,
    p_action: params.action,
    p_client_op_id: params.clientOpId,
    p_submission_id: params.submissionId ?? null,
  } as never)
  if (error) throw error
  return data as string
}

export async function cancelCommercialDocument(params: {
  documentId: string
  reason?: string | null
  clientOpId?: string
}): Promise<unknown> {
  const { data, error } = await supabase.rpc('cancel_commercial_document' as never, {
    p_document_id: params.documentId,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
    p_reason: params.reason ?? null,
  } as never)
  if (error) throw error
  return data
}

export async function createQuoteWaiver(params: {
  projectId: string
  workDescription: string
  legalText: string
  signature: Record<string, unknown>
  device?: string | null
  clientOpId?: string
}): Promise<unknown> {
  const { data, error } = await supabase.rpc('create_quote_waiver' as never, {
    p_project_id: params.projectId,
    p_legal_text: params.legalText,
    p_work_description: params.workDescription,
    p_signature: params.signature,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
    p_device: params.device ?? null,
  } as never)
  if (error) throw error
  return data
}

export async function recordPayment(params: {
  documentId: string
  amountCents: number
  method: string
  reference?: string | null
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('record_payment' as never, {
    p_document_id: params.documentId,
    p_amount_cents: params.amountCents,
    p_method: params.method,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
    p_reference: params.reference ?? null,
  } as never)
  if (error) throw error
  return data as string
}

export async function setDeliveryExternalInvoiceRef(params: {
  documentId: string
  ref: string | null
}): Promise<void> {
  const { error } = await supabase.rpc(
    'set_delivery_external_invoice_ref' as never,
    {
      p_document_id: params.documentId,
      p_ref: params.ref,
    } as never,
  )
  if (error) throw error
}

export type PaymentMethod = 'cash' | 'card' | 'transfer' | 'bizum' | 'payment_link'

export type CommercialPayment = {
  id: string
  tenant_id: string
  document_id: string
  amount_cents: number
  method: PaymentMethod | string
  reference: string | null
  collected_by: string | null
  occurred_at: string
  client_op_id: string
  created_at: string
}

export async function listDocumentPayments(
  documentId: string,
): Promise<CommercialPayment[]> {
  const { data, error } = await supabase
    .from('payments' as never)
    .select('*')
    .eq('document_id', documentId)
    .order('occurred_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as CommercialPayment[]
}

export async function listPaymentsForDocuments(
  documentIds: string[],
): Promise<CommercialPayment[]> {
  if (documentIds.length === 0) return []
  const { data, error } = await supabase
    .from('payments' as never)
    .select('*')
    .in('document_id', documentIds)
    .order('occurred_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as CommercialPayment[]
}

export async function getPayment(paymentId: string): Promise<CommercialPayment> {
  const { data, error } = await supabase
    .from('payments' as never)
    .select('*')
    .eq('id', paymentId)
    .maybeSingle()
  if (error) throw error
  if (!data) throw new Error('payment_not_found')
  return data as CommercialPayment
}

export async function listProjectCommercialDocuments(
  projectId: string,
): Promise<CommercialDocument[]> {
  const { data, error } = await supabase
    .from('commercial_documents' as never)
    .select('*')
    .eq('project_id', projectId)
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as CommercialDocument[]
}

export async function listCommercialDocumentsForClient(
  clientId: string,
): Promise<CommercialDocument[]> {
  const { data, error } = await supabase
    .from('commercial_documents' as never)
    .select('*')
    .eq('client_id', clientId)
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as CommercialDocument[]
}

export type CommercialDocumentSearchHit = CommercialDocument & {
  client_display_name: string | null
  project_name: string | null
}

export type SearchCommercialDocumentsParams = {
  q?: string | null
  docTypes?: Array<CommercialDocument['doc_type']> | null
  statuses?: string[] | null
  issuedFrom?: string | null
  issuedTo?: string | null
  expiredOnly?: boolean
  totalMin?: number | null
  totalMax?: number | null
  limit?: number
}

export async function searchCommercialDocuments(
  params: SearchCommercialDocumentsParams = {},
): Promise<CommercialDocumentSearchHit[]> {
  const { data, error } = await supabase.rpc('search_commercial_documents' as never, {
    p_q: params.q?.trim() || null,
    p_doc_types: params.docTypes?.length ? params.docTypes : null,
    p_statuses: params.statuses?.length ? params.statuses : null,
    p_issued_from: params.issuedFrom || null,
    p_issued_to: params.issuedTo || null,
    p_expired_only: params.expiredOnly ?? false,
    p_total_min: params.totalMin ?? null,
    p_total_max: params.totalMax ?? null,
    p_limit: params.limit ?? 100,
  } as never)
  if (error) throw error
  return (data ?? []) as CommercialDocumentSearchHit[]
}

export async function listCommercialDocumentsForProjects(
  projectIds: string[],
): Promise<CommercialDocument[]> {
  if (projectIds.length === 0) return []
  const { data, error } = await supabase
    .from('commercial_documents' as never)
    .select('*')
    .in('project_id', projectIds)
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as CommercialDocument[]
}

export async function projectHasQuoteWaiver(projectId: string): Promise<boolean> {
  const { data, error } = await supabase
    .from('quote_waivers' as never)
    .select('id')
    .eq('project_id', projectId)
    .limit(1)
  if (error) throw error
  return (data ?? []).length > 0
}

/** Map of projectId → true when a delivery note has unpaid balance. */
export async function getProjectsPaymentPending(
  projectIds: string[],
): Promise<Record<string, boolean>> {
  const result: Record<string, boolean> = {}
  for (const id of projectIds) result[id] = false
  if (projectIds.length === 0) return result

  const docs = await listCommercialDocumentsForProjects(projectIds)
  const deliveries = docs.filter((d) => d.doc_type === 'delivery_note')
  if (deliveries.length === 0) return result

  const payments = await listPaymentsForDocuments(docs.map((d) => d.id))

  // Latest delivery per project (docs already ordered created_at desc)
  const seen = new Set<string>()
  for (const doc of deliveries) {
    if (!doc.project_id || seen.has(doc.project_id)) continue
    seen.add(doc.project_id)
    result[doc.project_id] = remainingCentsForDocument(doc, docs, payments) > 0
  }
  return result
}

function asObject<T extends Record<string, unknown>>(value: unknown): T {
  return (value && typeof value === 'object' && !Array.isArray(value) ? value : {}) as T
}

export async function getCommercialDocumentDetail(
  documentId: string,
): Promise<CommercialDocumentDetail> {
  const { data: doc, error: docError } = await supabase
    .from('commercial_documents' as never)
    .select('*')
    .eq('id', documentId)
    .maybeSingle()
  if (docError) throw docError
  if (!doc) throw new Error('document_not_found')

  const { data: lines, error: linesError } = await supabase
    .from('commercial_document_lines' as never)
    .select('*')
    .eq('document_id', documentId)
    .order('position', { ascending: true })
  if (linesError) throw linesError

  const { data: events, error: eventsError } = await supabase
    .from('commercial_document_events' as never)
    .select('id, event_type, occurred_at, channel')
    .eq('document_id', documentId)
    .order('occurred_at', { ascending: true })
  if (eventsError) throw eventsError

  const row = doc as CommercialDocument & Record<string, unknown>
  return {
    id: row.id,
    tenant_id: row.tenant_id,
    doc_type: row.doc_type,
    doc_number: row.doc_number,
    client_id: row.client_id,
    project_id: row.project_id,
    status: row.status,
    seller_snapshot: asObject(row.seller_snapshot),
    buyer_snapshot: asObject(row.buyer_snapshot),
    service_address_snapshot: asObject(row.service_address_snapshot),
    terms_text: (row.terms_text as string | null | undefined) ?? null,
    locale: (row.locale as string | undefined) ?? 'ca',
    currency: (row.currency as string | undefined) ?? 'EUR',
    subtotal: Number(row.subtotal ?? 0),
    tax_breakdown: Array.isArray(row.tax_breakdown)
      ? (row.tax_breakdown as CommercialDocumentDetail['tax_breakdown'])
      : [],
    total: Number(row.total ?? 0),
    show_prices: row.show_prices !== false,
    issued_at: row.issued_at,
    valid_until: row.valid_until,
    parent_document_id: row.parent_document_id,
    created_at: row.created_at,
    rendered_document_id: (row.rendered_document_id as string | null | undefined) ?? null,
    pdf_job_id: (row.pdf_job_id as string | null | undefined) ?? null,
    document_template_id: (row.document_template_id as string | null | undefined) ?? null,
    full_body_template_id: (row.full_body_template_id as string | null | undefined) ?? null,
    lines: (lines ?? []) as CommercialDocumentLine[],
    events: (events ?? []) as CommercialDocumentDetail['events'],
  }
}

export async function recordCommercialDocumentSent(params: {
  documentId: string
  channel: string
  device?: string | null
  payload?: Record<string, unknown>
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('record_commercial_document_sent' as never, {
    p_document_id: params.documentId,
    p_channel: params.channel,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
    p_device: params.device ?? null,
    p_payload: params.payload ?? {},
  } as never)
  if (error) throw error
  return data as string
}

export type CommercialRenderResult = {
  status: 'ready' | 'pending' | 'unavailable'
  rendered_document_id?: string | null
  version_id?: string | null
  download_url?: string | null
  pdf_job_id?: string | null
  html_fallback?: boolean
  already_ready?: boolean
  error?: string | null
}

export async function renderCommercialDocumentPdf(params: {
  documentId: string
  tenantId: string
  regenerate?: boolean
  clientOpId?: string
}): Promise<CommercialRenderResult> {
  const { data, error } = await supabase.functions.invoke('render-commercial-document', {
    headers: { 'x-tenant-id': params.tenantId },
    body: {
      document_id: params.documentId,
      client_op_id: params.clientOpId ?? generateClientOpId(),
      regenerate: params.regenerate === true,
    },
  })
  if (error) {
    const detailed = await getFunctionErrorMessage(error)
    throw new Error(detailed ?? error.message)
  }
  const payload = (data ?? {}) as Record<string, unknown>
  if (payload.error) {
    const nested = payload.error as { message?: string; code?: string }
    throw new Error(nested.message ?? nested.code ?? 'render_failed')
  }
  const status =
    payload.status === 'pending'
      ? 'pending'
      : payload.status === 'unavailable'
        ? 'unavailable'
        : 'ready'
  return {
    status,
    rendered_document_id: (payload.rendered_document_id as string | null | undefined) ?? null,
    version_id: (payload.version_id as string | null | undefined) ?? null,
    download_url: (payload.download_url as string | null | undefined) ?? null,
    pdf_job_id: (payload.pdf_job_id as string | null | undefined) ?? null,
    html_fallback: payload.html_fallback === true,
    already_ready: payload.already_ready === true,
    error: typeof payload.error === 'string' ? payload.error : null,
  }
}

export async function getCommercialPdfJobStatus(params: {
  jobId: string
  tenantId: string
}): Promise<{
  status: string
  result_document_id: string | null
  last_error_message: string | null
} | null> {
  const { data, error } = await supabase.rpc('get_pdf_job_status' as never, {
    p_job_id: params.jobId,
    p_tenant_id: params.tenantId,
  } as never)
  if (error) throw error
  if (!data || typeof data !== 'object') return null
  const row = data as Record<string, unknown>
  return {
    status: String(row.status ?? ''),
    result_document_id: (row.result_document_id as string | null | undefined) ?? null,
    last_error_message: (row.last_error_message as string | null | undefined) ?? null,
  }
}

export async function getCommercialFullBodyLocale(params: {
  tenantId: string
  templateId: string
  locale: string
}): Promise<{ template_type: string; html_content: string | null; storage_path: string | null } | null> {
  const { data, error } = await supabase.rpc('get_commercial_full_body_locale' as never, {
    p_tenant_id: params.tenantId,
    p_template_id: params.templateId,
    p_locale: params.locale,
  } as never)
  if (error) throw error
  if (data == null) return null
  const row = data as {
    template_type?: string
    html_content?: string | null
    storage_path?: string | null
  }
  if (!row.template_type) return null
  return {
    template_type: row.template_type,
    html_content: typeof row.html_content === 'string' ? row.html_content : null,
    storage_path: typeof row.storage_path === 'string' ? row.storage_path : null,
  }
}

export async function getCommercialIssuedPreviewContext(params: {
  tenantId: string
  parentDocumentId?: string | null
}): Promise<{
  tenant: {
    name: string | null
    address: string | null
    phone: string | null
    email: string | null
  }
  parentDocNumber: string | null
}> {
  const tenantQuery = supabase
    .from('tenants')
    .select('name')
    .eq('id', params.tenantId)
    .maybeSingle()
  const parentQuery = params.parentDocumentId
    ? supabase
        .from('commercial_documents' as never)
        .select('doc_number')
        .eq('id', params.parentDocumentId)
        .eq('tenant_id', params.tenantId)
        .maybeSingle()
    : Promise.resolve({ data: null as { doc_number?: string | null } | null, error: null })

  const [{ data: tenant, error: tenantError }, parentResult] = await Promise.all([
    tenantQuery,
    parentQuery,
  ])
  if (tenantError) throw tenantError
  if (parentResult.error) throw parentResult.error
  const parentRow = parentResult.data as { doc_number?: string | null } | null
  return {
    tenant: {
      name: typeof tenant?.name === 'string' && tenant.name.trim() ? tenant.name.trim() : null,
      address: null,
      phone: null,
      email: null,
    },
    parentDocNumber:
      typeof parentRow?.doc_number === 'string' && parentRow.doc_number.trim()
        ? parentRow.doc_number.trim()
        : null,
  }
}

export async function getCommercialDisplayFormats(tenantId: string): Promise<{
  dateFormat: string
  timeFormat: string
}> {
  const { data, error } = await supabase.rpc('get_commercial_display_formats' as never, {
    p_tenant_id: tenantId,
  } as never)
  if (error) throw error
  const row = (data && typeof data === 'object' ? data : {}) as Record<string, unknown>
  const dateFormat =
    typeof row.date_format === 'string' && row.date_format.trim()
      ? row.date_format.trim()
      : 'dd/MM/yyyy'
  const timeFormat =
    typeof row.time_format === 'string' && row.time_format.trim()
      ? row.time_format.trim()
      : 'HH:mm'
  return { dateFormat, timeFormat }
}
