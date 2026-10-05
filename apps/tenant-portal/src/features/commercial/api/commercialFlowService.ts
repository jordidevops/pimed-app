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
import {
  parseCommercialInclusion,
  type CommercialInclusion,
} from '../utils/agreementInclusion'

export type { CommercialInclusion }

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
  doc_type: 'quote' | 'quote_amendment' | 'delivery_note' | 'invoice'
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
  full_body_template_id?: string | null
  formalization_mode?: 'signed_quote' | 'separate_agreement' | null
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

export type DeliveryNotePreviewLine = {
  project_line_id: string
  name: string
  unit: string
  quantity: number
  line_total: number
}

export type DeliveryNotePreview = {
  subtotal: number
  total: number
  lines: DeliveryNotePreviewLine[]
}

export async function previewDeliveryNote(projectId: string): Promise<DeliveryNotePreview> {
  const { data, error } = await supabase.rpc('preview_delivery_note' as never, {
    p_project_id: projectId,
  } as never)
  if (error) throw error
  const row = (data ?? {}) as {
    subtotal?: number
    total?: number
    lines?: DeliveryNotePreviewLine[]
  }
  return {
    subtotal: Number(row.subtotal ?? 0),
    total: Number(row.total ?? 0),
    lines: Array.isArray(row.lines) ? row.lines : [],
  }
}

export async function issueCommercialDocument(params: {
  projectId: string
  docType: 'quote' | 'quote_amendment' | 'delivery_note'
  showPrices?: boolean
  parentDocumentId?: string | null
  clientOpId?: string
  formalizationMode?: 'signed_quote' | 'separate_agreement' | null
  fullBodyTemplateId?: string | null
}): Promise<string> {
  const { data, error } = await supabase.rpc('issue_commercial_document' as never, {
    p_project_id: params.projectId,
    p_doc_type: params.docType,
    p_show_prices: params.showPrices ?? true,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
    p_parent_document_id: params.parentDocumentId ?? null,
    p_formalization_mode:
      params.docType === 'delivery_note' ? null : (params.formalizationMode ?? null),
    p_full_body_template_id:
      params.docType === 'delivery_note' ? null : (params.fullBodyTemplateId ?? null),
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

export type RectifyLinePatch = {
  project_line_id: string
  quantity: number
}

export type RectifyDeliveryPreview = {
  document_id: string
  doc_number: string | null
  project_id: string | null
  subtotal: number
  total: number
  total_cents: number
  inherited_paid_cents: number
  payments_exceed_total: boolean
  lines: Array<{
    project_line_id: string
    name: string
    description: string | null
    unit: string | null
    quantity: number
    os_quantity: number
    min_os_quantity: number
    other_delivered_quantity: number
    unit_price: number
    discount_pct: number
    tax_rate: number
    line_subtotal: number
    line_tax: number
    line_total: number
  }>
}

export type DeliveryNoteCollectionDetail = {
  id: string
  doc_number: string | null
  status: string
  total_cents: number
  direct_paid_cents: number
  inherited_paid_cents: number
  advance_applied_cents: number
  paid_cents: number
  remaining_cents: number
  external_invoice_ref: string | null
  invoiced: boolean
}

export async function previewRectifyDeliveryNote(params: {
  documentId: string
  linePatches?: RectifyLinePatch[]
}): Promise<RectifyDeliveryPreview> {
  const { data, error } = await supabase.rpc('preview_rectify_delivery_note' as never, {
    p_document_id: params.documentId,
    p_line_patches: params.linePatches ?? [],
  } as never)
  if (error) throw error
  return data as RectifyDeliveryPreview
}

export async function rectifyCommercialDelivery(params: {
  documentId: string
  reason: string
  linePatches?: RectifyLinePatch[]
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('rectify_delivery_note' as never, {
    p_document_id: params.documentId,
    p_reason: params.reason,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
    p_line_patches: params.linePatches ?? [],
  } as never)
  if (error) throw error
  return data as string
}

export async function getDeliveryNoteCollectionDetail(
  documentId: string,
): Promise<DeliveryNoteCollectionDetail> {
  const { data, error } = await supabase.rpc(
    'get_delivery_note_collection_detail' as never,
    { p_document_id: documentId } as never,
  )
  if (error) throw error
  return data as DeliveryNoteCollectionDetail
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

export type DeliveryCollectionStatus = 'pending' | 'partial' | 'paid'

export type DeliveryCollectionRow = {
  id: string
  tenant_id: string
  doc_number: string | null
  client_id: string | null
  client_display_name: string | null
  project_id: string | null
  project_name: string | null
  document_status: string
  collection_status: DeliveryCollectionStatus
  total: number
  total_cents: number
  paid_cents: number
  remaining_cents: number
  own_paid_cents: number
  advance_cents: number
  issued_at: string | null
  created_at: string
  external_invoice_ref: string | null
}

export type ListDeliveryCollectionParams = {
  clientId?: string | null
  projectId?: string | null
  statusGroup?: 'open' | 'pending' | 'partial' | 'paid' | 'all'
  hasExternalRef?: 'all' | 'yes' | 'no'
  q?: string | null
  issuedFrom?: string | null
  issuedTo?: string | null
  limit?: number
  offset?: number
}

export type DeliveryCollectionPage = {
  items: DeliveryCollectionRow[]
  totalCount: number
  totalRemainingCents: number
}

export type DeliveryNoteListStatus = 'pending' | 'partial' | 'paid' | 'rectified'
export type SalesBillingStatus = 'to_invoice' | 'draft_invoice' | 'invoiced' | 'rectified'

export type DeliveryNoteListRow = {
  id: string
  doc_number: string | null
  client_id: string | null
  client_display_name: string | null
  project_id: string | null
  project_name: string | null
  document_status: string
  collection_status: DeliveryNoteListStatus
  /** Present on sales-hub rows; drives draft vs invoiced UI. */
  billing_status?: SalesBillingStatus
  total: number
  total_cents: number
  direct_paid_cents: number
  inherited_paid_cents: number
  advance_applied_cents: number
  paid_cents: number
  remaining_cents: number
  issued_at: string | null
  created_at: string
  external_invoice_id: string | null
  external_invoice_ref: string | null
  supersedes_id: string | null
  superseded_by_id: string | null
  superseded_by_number: string | null
}

export type ListDeliveryNotesParams = ListDeliveryCollectionParams & {
  includeRectified?: boolean
}

export type DeliveryNotesPageResult = {
  items: DeliveryNoteListRow[]
  totalCount: number
  totalCents: number
  totalPaidCents: number
  totalRemainingCents: number
}

export async function listDeliveryNotesPage(
  params: ListDeliveryNotesParams = {},
): Promise<DeliveryNotesPageResult> {
  const { data, error } = await supabase.rpc('list_delivery_notes_page' as never, {
    p_client_id: params.clientId || null,
    p_project_id: params.projectId || null,
    p_status_group: params.statusGroup ?? 'open',
    p_has_external_ref: params.hasExternalRef ?? 'all',
    p_q: params.q?.trim() || null,
    p_issued_from: params.issuedFrom || null,
    p_issued_to: params.issuedTo || null,
    p_include_rectified: params.includeRectified ?? false,
    p_limit: params.limit ?? 50,
    p_offset: params.offset ?? 0,
  } as never)
  if (error) throw error
  const row = (Array.isArray(data) ? data[0] : data) as {
    items?: DeliveryNoteListRow[] | null
    total_count?: number | string | null
    total_cents?: number | string | null
    total_paid_cents?: number | string | null
    total_remaining_cents?: number | string | null
  } | null
  return {
    items: (row?.items ?? []) as DeliveryNoteListRow[],
    totalCount: Number(row?.total_count ?? 0),
    totalCents: Number(row?.total_cents ?? 0),
    totalPaidCents: Number(row?.total_paid_cents ?? 0),
    totalRemainingCents: Number(row?.total_remaining_cents ?? 0),
  }
}

export type ExternalInvoiceListRow = {
  id: string
  invoice_number: string
  client_id: string
  client_display_name: string
  issued_on: string
  total_cents: number
  notes_total_cents: number
  difference_cents: number
  delivery_count: number
  delivery_numbers: string[]
  paid_cents: number
  remaining_cents: number
}

export async function listExternalInvoicesPage(params: {
  clientId?: string | null
  projectId?: string | null
  q?: string | null
  limit?: number
  offset?: number
} = {}): Promise<{ items: ExternalInvoiceListRow[]; totalCount: number; totalRemainingCents: number }> {
  const { data, error } = await supabase.rpc('list_external_invoices_page' as never, {
    p_client_id: params.clientId || null,
    p_project_id: params.projectId || null,
    p_q: params.q?.trim() || null,
    p_limit: params.limit ?? 50,
    p_offset: params.offset ?? 0,
  } as never)
  if (error) throw error
  const row = (Array.isArray(data) ? data[0] : data) as {
    items?: ExternalInvoiceListRow[] | null
    total_count?: number | string | null
    total_remaining_cents?: number | string | null
  } | null
  return {
    items: (row?.items ?? []) as ExternalInvoiceListRow[],
    totalCount: Number(row?.total_count ?? 0),
    totalRemainingCents: Number(row?.total_remaining_cents ?? 0),
  }
}

export async function createInvoiceDraftFromDeliveryNotes(params: {
  deliveryNoteIds: string[]
  issuedOn?: string | null
  notes?: string | null
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc(
    'create_invoice_draft_from_delivery_notes' as never,
    {
      p_delivery_note_ids: params.deliveryNoteIds,
      p_client_op_id: params.clientOpId ?? generateClientOpId(),
      p_issued_on: params.issuedOn ?? null,
      p_notes: params.notes ?? null,
    } as never,
  )
  if (error) throw error
  return String(data ?? '')
}

export async function issueInvoice(params: {
  invoiceId: string
  issuedOn?: string | null
  seriesId?: string | null
  docNumber?: string | null
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('issue_invoice' as never, {
    p_invoice_id: params.invoiceId,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
    p_issued_on: params.issuedOn ?? null,
    p_series_id: params.seriesId ?? null,
    p_doc_number: params.docNumber ?? null,
  } as never)
  if (error) throw error
  return String(data ?? params.invoiceId)
}

export async function cancelInvoice(params: {
  invoiceId: string
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('cancel_invoice' as never, {
    p_invoice_id: params.invoiceId,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
  return String(data ?? params.invoiceId)
}

/** Create draft then issue (native path replacing register_external_invoice writes). */
export async function setCommercialDocumentExternalRef(params: {
  documentId: string
  externalNumber: string | null
  provider?: string
  externalId?: string | null
}): Promise<void> {
  const { error } = await supabase.rpc('set_commercial_document_external_ref' as never, {
    p_document_id: params.documentId,
    p_external_number: params.externalNumber,
    p_provider: params.provider ?? 'manual',
    p_external_id: params.externalId ?? null,
  } as never)
  if (error) throw error
}

function isMissingRpcError(err: unknown): boolean {
  if (typeof err !== 'object' || err === null) return false
  const row = err as { code?: unknown; message?: unknown; details?: unknown }
  if (row.code === 'PGRST202') return true
  const blob = `${typeof row.message === 'string' ? row.message : ''}\n${
    typeof row.details === 'string' ? row.details : ''
  }`
  return blob.includes('Could not find the function') || blob.includes('schema cache')
}

export async function issueInvoiceFromDeliveryNotes(params: {
  deliveryNoteIds: string[]
  issuedOn: string
  /** Optional ERP / external reference — does not become PiMed doc_number. */
  erpReference?: string | null
  /** @deprecated Prefer erpReference; forced doc numbers skip series allocation. */
  invoiceNumber?: string | null
  notes?: string | null
  allocateNumber?: boolean
  clientOpId?: string
}): Promise<{ id: string; differenceCents: number; docNumber?: string | null }> {
  const clientOpId = params.clientOpId ?? generateClientOpId()
  const forcedNumber =
    params.allocateNumber === false || Boolean(params.invoiceNumber)
      ? (params.invoiceNumber ?? null)
      : null

  // Forced doc_number is legacy/rare; keep create+issue. Normal path is one TX RPC.
  if (forcedNumber) {
    const draftId = await createInvoiceDraftFromDeliveryNotes({
      deliveryNoteIds: params.deliveryNoteIds,
      issuedOn: params.issuedOn,
      notes: params.notes,
      clientOpId,
    })
    try {
      const issuedId = await issueInvoice({
        invoiceId: draftId,
        issuedOn: params.issuedOn,
        docNumber: forcedNumber,
        clientOpId,
      })
      return { id: issuedId, differenceCents: 0 }
    } catch (err) {
      try {
        await cancelInvoice({ invoiceId: draftId, clientOpId: generateClientOpId() })
      } catch {
        // best-effort discard
      }
      throw err
    }
  }

  const { data, error } = await supabase.rpc('issue_invoice_from_delivery_notes' as never, {
    p_delivery_note_ids: params.deliveryNoteIds,
    p_client_op_id: clientOpId,
    p_issued_on: params.issuedOn || null,
    p_notes: params.notes ?? null,
    p_erp_reference: params.erpReference?.trim() || null,
  } as never)
  if (error) throw error
  return { id: String(data ?? ''), differenceCents: 0 }
}

export async function registerExternalInvoice(params: {
  invoiceNumber: string
  issuedOn: string
  totalCents: number
  deliveryNoteIds: string[]
  notes?: string | null
}): Promise<{ id: string; differenceCents: number }> {
  // Prefer native draft+issue; fall back to compatibility RPC only if the RPC is missing.
  try {
    return await issueInvoiceFromDeliveryNotes({
      deliveryNoteIds: params.deliveryNoteIds,
      issuedOn: params.issuedOn,
      invoiceNumber: params.invoiceNumber,
      notes: params.notes,
    })
  } catch (err) {
    if (!isMissingRpcError(err)) throw err
    const { data, error } = await supabase.rpc('register_external_invoice' as never, {
      p_invoice_number: params.invoiceNumber,
      p_issued_on: params.issuedOn,
      p_total_cents: params.totalCents,
      p_delivery_note_ids: params.deliveryNoteIds,
      p_client_op_id: generateClientOpId(),
      p_notes: params.notes ?? null,
    } as never)
    if (error) throw error
    const row = data as { id?: string; difference_cents?: number | string | null }
    return {
      id: String(row?.id ?? ''),
      differenceCents: Number(row?.difference_cents ?? 0),
    }
  }
}

export type InvoicePaymentResult = {
  paymentId: string
  amountCents: number
  allocations: Array<{
    delivery_note_id: string
    amount_cents: number
    position: number
  }>
  idempotent: boolean
}

export async function recordInvoicePayment(params: {
  invoiceId: string
  amountCents: number
  method: string
  reference?: string | null
  clientOpId?: string
}): Promise<InvoicePaymentResult> {
  const { data, error } = await supabase.rpc('record_invoice_payment' as never, {
    p_invoice_id: params.invoiceId,
    p_amount_cents: params.amountCents,
    p_method: params.method,
    p_reference: params.reference ?? null,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
  if (typeof data === 'string') {
    return {
      paymentId: data,
      amountCents: params.amountCents,
      allocations: [],
      idempotent: false,
    }
  }
  const row = (data ?? {}) as {
    payment_id?: string
    amount_cents?: number | string
    allocations?: InvoicePaymentResult['allocations']
    idempotent?: boolean
  }
  return {
    paymentId: String(row.payment_id ?? ''),
    amountCents: Number(row.amount_cents ?? params.amountCents),
    allocations: Array.isArray(row.allocations) ? row.allocations : [],
    idempotent: Boolean(row.idempotent),
  }
}

// ---------------------------------------------------------------------------
// CF-27 Sales list / accounting / numbering RPCs
// ---------------------------------------------------------------------------

export type SalesCollectionStatus = 'pending' | 'partial' | 'paid'
export type SalesDocumentStatus = 'draft' | 'issued' | 'cancelled'
export type SalesReviewStatus = 'pending' | 'reviewed' | 'needs_changes'
export type SalesExportStatus = 'none' | 'preparing' | 'exported'

export type SalesListCursor = {
  value: string
  id: string
}

export type SalesDeliveryNoteListRow = {
  id: string
  doc_number: string | null
  client_id: string | null
  client_display_name: string | null
  project_id: string | null
  project_name: string | null
  document_status: string
  billing_status: SalesBillingStatus
  collection_status: SalesCollectionStatus
  total: number
  total_cents: number
  paid_cents: number
  remaining_cents: number
  issued_at: string | null
  issued_on: string | null
  created_at: string
  invoice_id: string | null
  invoice_doc_number: string | null
}

export type SalesInvoiceListRow = {
  id: string
  doc_number: string | null
  client_id: string | null
  client_display_name: string | null
  document_status: SalesDocumentStatus | string
  collection_status: SalesCollectionStatus
  delivery_count: number
  delivery_numbers: string[]
  total: number
  total_cents: number
  paid_cents: number
  remaining_cents: number
  issued_at: string | null
  issued_on: string | null
  created_at: string
  external_ref: string | null
  external_provider: string | null
  review_status: SalesReviewStatus | string
  export_status: SalesExportStatus | string
  export_batch_id?: string | null
}

export type SalesListPageResult<T> = {
  items: T[]
  totalCount: number
  nextCursor: SalesListCursor | null
  hasMore: boolean
}

function parseSalesListPage<T>(data: unknown): SalesListPageResult<T> {
  const row = (Array.isArray(data) ? data[0] : data) as {
    items?: T[] | null
    total_count?: number | string | null
    next_cursor_value?: string | null
    next_cursor_id?: string | null
    has_more?: boolean | null
  } | null
  const nextValue = row?.next_cursor_value ?? null
  const nextId = row?.next_cursor_id ?? null
  return {
    items: (row?.items ?? []) as T[],
    totalCount: Number(row?.total_count ?? 0),
    nextCursor:
      nextValue != null && nextId != null ? { value: String(nextValue), id: String(nextId) } : null,
    hasMore: Boolean(row?.has_more),
  }
}

export type ListSalesDeliveryNotesParams = {
  clientId?: string | null
  projectId?: string | null
  q?: string | null
  billingStatus?: SalesBillingStatus[] | null
  collectionStatus?: SalesCollectionStatus[] | null
  year?: number | null
  dateFrom?: string | null
  dateTo?: string | null
  sort?: 'issued_at' | 'doc_number' | 'total'
  dir?: 'asc' | 'desc'
  cursor?: SalesListCursor | null
  limit?: number
}

export async function listSalesDeliveryNotesPage(
  params: ListSalesDeliveryNotesParams = {},
): Promise<SalesListPageResult<SalesDeliveryNoteListRow>> {
  const { data, error } = await supabase.rpc('list_sales_delivery_notes_page' as never, {
    p_client_id: params.clientId || null,
    p_project_id: params.projectId || null,
    p_q: params.q?.trim() || null,
    p_billing_status: params.billingStatus?.length ? params.billingStatus : null,
    p_collection_status: params.collectionStatus?.length ? params.collectionStatus : null,
    p_year: params.year ?? null,
    p_date_from: params.dateFrom || null,
    p_date_to: params.dateTo || null,
    p_sort: params.sort ?? 'issued_at',
    p_dir: params.dir ?? 'desc',
    p_cursor_value: params.cursor?.value ?? null,
    p_cursor_id: params.cursor?.id ?? null,
    p_limit: params.limit ?? 50,
  } as never)
  if (error) throw error
  const page = parseSalesListPage<SalesDeliveryNoteListRow>(data)
  return {
    ...page,
    items: page.items.map((row) => ({
      ...row,
      total: Number(row.total ?? 0),
      total_cents: Number(row.total_cents ?? 0),
      paid_cents: Number(row.paid_cents ?? 0),
      remaining_cents: Number(row.remaining_cents ?? 0),
    })),
  }
}

export type ListSalesInvoicesParams = {
  clientId?: string | null
  projectId?: string | null
  q?: string | null
  documentStatus?: SalesDocumentStatus[] | null
  collectionStatus?: SalesCollectionStatus[] | null
  year?: number | null
  dateFrom?: string | null
  dateTo?: string | null
  sort?: 'issued_at' | 'doc_number' | 'total'
  dir?: 'asc' | 'desc'
  cursor?: SalesListCursor | null
  limit?: number
}

export async function listSalesInvoicesPage(
  params: ListSalesInvoicesParams = {},
): Promise<SalesListPageResult<SalesInvoiceListRow>> {
  const { data, error } = await supabase.rpc('list_sales_invoices_page' as never, {
    p_client_id: params.clientId || null,
    p_project_id: params.projectId || null,
    p_q: params.q?.trim() || null,
    p_document_status: params.documentStatus?.length ? params.documentStatus : null,
    p_collection_status: params.collectionStatus?.length ? params.collectionStatus : null,
    p_year: params.year ?? null,
    p_date_from: params.dateFrom || null,
    p_date_to: params.dateTo || null,
    p_sort: params.sort ?? 'issued_at',
    p_dir: params.dir ?? 'desc',
    p_cursor_value: params.cursor?.value ?? null,
    p_cursor_id: params.cursor?.id ?? null,
    p_limit: params.limit ?? 50,
  } as never)
  if (error) throw error
  const page = parseSalesListPage<SalesInvoiceListRow & { delivery_numbers?: unknown }>(data)
  return {
    ...page,
    items: page.items.map((row) => ({
      ...row,
      delivery_numbers: Array.isArray(row.delivery_numbers)
        ? (row.delivery_numbers as string[])
        : [],
      total_cents: Number(row.total_cents ?? 0),
      paid_cents: Number(row.paid_cents ?? 0),
      remaining_cents: Number(row.remaining_cents ?? 0),
      delivery_count: Number(row.delivery_count ?? 0),
      total: Number(row.total ?? 0),
    })),
  }
}

export type SalesDashboardKpis = {
  toInvoiceCount: number
  toInvoiceCents: number
  pendingCollectionCents: number
  pendingQuotesCount: number
  year: number
}

export type SalesDashboardAttentionReason =
  | 'needs_prepare'
  | 'pending_signature'
  | 'draft'
  | 'expiring'
  | 'suspended'

export type SalesDashboardAttentionItem = {
  kind: 'agreement' | 'quote_prepare'
  id: string
  clientId: string | null
  clientName: string
  label: string
  reason: SalesDashboardAttentionReason
}

export type SalesDashboardOverview = {
  year: number
  cash: SalesDashboardKpis
  agreements: {
    signature: { draft: number; pending: number; signed: number }
    lifecycle: { active: number; expiring: number; suspended: number; finished: number }
    needsPrepareCount: number
    attention: SalesDashboardAttentionItem[]
  }
  series: {
    months: Array<{
      month: number
      quotesIssued: number
      deliveryNotesIssued: number
      invoicedCents: number
    }>
  }
}

function mapSalesDashboardCash(
  cash: {
    to_invoice_count?: number | string | null
    to_invoice_cents?: number | string | null
    pending_collection_cents?: number | string | null
    pending_quotes_count?: number | string | null
  },
  year: number,
): SalesDashboardKpis {
  return {
    toInvoiceCount: Number(cash.to_invoice_count ?? 0),
    toInvoiceCents: Number(cash.to_invoice_cents ?? 0),
    pendingCollectionCents: Number(cash.pending_collection_cents ?? 0),
    pendingQuotesCount: Number(cash.pending_quotes_count ?? 0),
    year,
  }
}

export async function getSalesDashboardOverview(
  year: number = new Date().getFullYear(),
): Promise<SalesDashboardOverview> {
  const { data, error } = await supabase.rpc('get_sales_dashboard_overview' as never, {
    p_year: year,
  } as never)
  if (error) throw error
  const row = (data ?? {}) as {
    year?: number | string | null
    cash?: {
      to_invoice_count?: number | string | null
      to_invoice_cents?: number | string | null
      pending_collection_cents?: number | string | null
      pending_quotes_count?: number | string | null
    } | null
    agreements?: {
      signature?: {
        draft?: number | string | null
        pending?: number | string | null
        signed?: number | string | null
      } | null
      lifecycle?: {
        active?: number | string | null
        expiring?: number | string | null
        suspended?: number | string | null
        finished?: number | string | null
      } | null
      needs_prepare_count?: number | string | null
      attention?: Array<{
        kind?: string | null
        id?: string | null
        client_id?: string | null
        client_name?: string | null
        label?: string | null
        reason?: string | null
      }> | null
    } | null
    series?: {
      months?: Array<{
        month?: number | string | null
        quotes_issued?: number | string | null
        delivery_notes_issued?: number | string | null
        invoiced_cents?: number | string | null
      }> | null
    } | null
  }

  const resolvedYear = Number(row.year ?? year)
  const attention = Array.isArray(row.agreements?.attention) ? row.agreements!.attention! : []
  const months = Array.isArray(row.series?.months) ? row.series!.months! : []

  return {
    year: resolvedYear,
    cash: mapSalesDashboardCash(row.cash ?? {}, resolvedYear),
    agreements: {
      signature: {
        draft: Number(row.agreements?.signature?.draft ?? 0),
        pending: Number(row.agreements?.signature?.pending ?? 0),
        signed: Number(row.agreements?.signature?.signed ?? 0),
      },
      lifecycle: {
        active: Number(row.agreements?.lifecycle?.active ?? 0),
        expiring: Number(row.agreements?.lifecycle?.expiring ?? 0),
        suspended: Number(row.agreements?.lifecycle?.suspended ?? 0),
        finished: Number(row.agreements?.lifecycle?.finished ?? 0),
      },
      needsPrepareCount: Number(row.agreements?.needs_prepare_count ?? 0),
      attention: attention
        .filter((item): item is NonNullable<typeof item> & { id: string; reason: string } =>
          Boolean(item?.id && item?.reason),
        )
        .map((item) => ({
          kind: item.kind === 'quote_prepare' ? 'quote_prepare' : 'agreement',
          id: item.id,
          clientId: item.client_id ?? null,
          clientName: item.client_name ?? '',
          label: item.label ?? '',
          reason: item.reason as SalesDashboardAttentionReason,
        })),
    },
    series: {
      months: Array.from({ length: 12 }, (_, index) => {
        const month = index + 1
        const found = months.find((m) => Number(m.month) === month)
        return {
          month,
          quotesIssued: Number(found?.quotes_issued ?? 0),
          deliveryNotesIssued: Number(found?.delivery_notes_issued ?? 0),
          invoicedCents: Number(found?.invoiced_cents ?? 0),
        }
      }),
    },
  }
}

/** @deprecated Prefer getSalesDashboardOverview; thin alias of overview.cash */
export async function getSalesDashboardKpis(
  year: number = new Date().getFullYear(),
): Promise<SalesDashboardKpis> {
  const overview = await getSalesDashboardOverview(year)
  return overview.cash
}

export type AccountingReviewResult = {
  documentId: string
  status: SalesReviewStatus | string
  comment: string | null
  revision: number
  reviewedBy: string | null
  reviewedAt: string | null
  idempotent: boolean
}

export async function upsertAccountingReview(params: {
  documentId: string
  status: SalesReviewStatus
  comment?: string | null
  clientOpId?: string
}): Promise<AccountingReviewResult> {
  const { data, error } = await supabase.rpc('upsert_accounting_review' as never, {
    p_document_id: params.documentId,
    p_status: params.status,
    p_comment: params.comment ?? null,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
  const row = (data ?? {}) as {
    document_id?: string
    status?: string
    comment?: string | null
    revision?: number | string
    reviewed_by?: string | null
    reviewed_at?: string | null
    idempotent?: boolean
  }
  return {
    documentId: String(row.document_id ?? params.documentId),
    status: (row.status ?? params.status) as SalesReviewStatus,
    comment: row.comment ?? null,
    revision: Number(row.revision ?? 1),
    reviewedBy: row.reviewed_by ?? null,
    reviewedAt: row.reviewed_at ?? null,
    idempotent: Boolean(row.idempotent),
  }
}

export type CommercialExportBatchPrepareResult = {
  batchId: string
  profileId: string
  status: string
  rowCount: number
  failedCount: number
  periodFrom: string
  periodTo: string
}

export async function prepareCommercialExportBatch(params: {
  periodFrom: string
  periodTo: string
  profileId?: string | null
  clientOpId?: string
}): Promise<CommercialExportBatchPrepareResult> {
  const { data, error } = await supabase.rpc('prepare_commercial_export_batch' as never, {
    p_period_from: params.periodFrom,
    p_period_to: params.periodTo,
    p_profile_id: params.profileId ?? null,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
  const row = (data ?? {}) as {
    batch_id?: string
    profile_id?: string
    status?: string
    row_count?: number | string
    failed_count?: number | string
    period_from?: string
    period_to?: string
  }
  return {
    batchId: String(row.batch_id ?? ''),
    profileId: String(row.profile_id ?? ''),
    status: String(row.status ?? 'preparing'),
    rowCount: Number(row.row_count ?? 0),
    failedCount: Number(row.failed_count ?? 0),
    periodFrom: String(row.period_from ?? params.periodFrom),
    periodTo: String(row.period_to ?? params.periodTo),
  }
}

export type CommercialExportBatchFinalizeResult = {
  batchId: string
  status: string
  rowCount: number
  failedCount: number
  checksum: string | null
  finalizedAt: string | null
  expiresAt?: string | null
}

export async function finalizeCommercialExportBatch(
  batchId: string,
): Promise<CommercialExportBatchFinalizeResult> {
  const { data, error } = await supabase.rpc('finalize_commercial_export_batch' as never, {
    p_batch_id: batchId,
  } as never)
  if (error) throw error
  const row = (data ?? {}) as {
    batch_id?: string
    status?: string
    row_count?: number | string
    failed_count?: number | string
    checksum?: string | null
    finalized_at?: string | null
    expires_at?: string | null
  }
  return {
    batchId: String(row.batch_id ?? batchId),
    status: String(row.status ?? 'ready'),
    rowCount: Number(row.row_count ?? 0),
    failedCount: Number(row.failed_count ?? 0),
    checksum: row.checksum ?? null,
    finalizedAt: row.finalized_at ?? null,
    expiresAt: row.expires_at ?? null,
  }
}

export type CommercialExportPackage = {
  manifest?: Record<string, unknown>
  checksum?: string
  files?: Record<string, string>
}

export type CommercialExportBatchClaimResult = {
  batchId: string
  status: string
  checksum: string | null
  rowCount: number
  failedCount: number
  periodFrom: string | null
  periodTo: string | null
  package: CommercialExportPackage | null
  expiresAt: string | null
}

export async function claimCommercialExportBatch(
  batchId: string,
): Promise<CommercialExportBatchClaimResult> {
  const { data, error } = await supabase.rpc('claim_commercial_export_batch' as never, {
    p_batch_id: batchId,
  } as never)
  if (error) throw error
  const row = (data ?? {}) as {
    batch_id?: string
    status?: string
    checksum?: string | null
    row_count?: number | string
    failed_count?: number | string
    period_from?: string | null
    period_to?: string | null
    package?: CommercialExportPackage | null
    expires_at?: string | null
  }
  return {
    batchId: String(row.batch_id ?? batchId),
    status: String(row.status ?? 'ready'),
    checksum: row.checksum ?? null,
    rowCount: Number(row.row_count ?? 0),
    failedCount: Number(row.failed_count ?? 0),
    periodFrom: row.period_from ?? null,
    periodTo: row.period_to ?? null,
    package: row.package ?? null,
    expiresAt: row.expires_at ?? null,
  }
}

export type CommercialExportBatchListRow = {
  id: string
  profile_id: string
  period_from: string
  period_to: string
  status: string
  schema_version: string
  row_count: number
  failed_count: number
  checksum: string | null
  created_at: string
  finalized_at: string | null
  claimed_at: string | null
  expires_at: string | null
  error_text: string | null
}

export async function listCommercialExportBatches(limit = 20): Promise<CommercialExportBatchListRow[]> {
  const { data, error } = await supabase
    .from('commercial_export_batches' as never)
    .select(
      'id, profile_id, period_from, period_to, status, schema_version, row_count, failed_count, checksum, created_at, finalized_at, claimed_at, expires_at, error_text',
    )
    .order('created_at', { ascending: false })
    .limit(limit)
  if (error) throw error
  return ((data ?? []) as CommercialExportBatchListRow[]).map((row) => ({
    ...row,
    row_count: Number(row.row_count ?? 0),
    failed_count: Number(row.failed_count ?? 0),
  }))
}

export type CommercialDocumentSeries = {
  id: string
  tenant_id: string
  doc_type: string
  code: string
  name: string
  pattern: string
  reset_policy: string
  active: boolean
  created_at: string
  updated_at: string
}

export async function listCommercialDocumentSeries(): Promise<CommercialDocumentSeries[]> {
  const { data, error } = await supabase
    .from('commercial_document_series' as never)
    .select('*')
    .order('doc_type')
    .order('code')
  if (error) throw error
  return (data ?? []) as CommercialDocumentSeries[]
}

export type CommercialFiscalYear = {
  tenant_id: string
  year: number
  closed_at: string | null
  closed_by: string | null
  reopened_at: string | null
  reopened_by: string | null
  created_at: string
}

export async function listCommercialFiscalYears(): Promise<CommercialFiscalYear[]> {
  const { data, error } = await supabase
    .from('commercial_fiscal_years' as never)
    .select('*')
    .order('year', { ascending: false })
  if (error) throw error
  return ((data ?? []) as CommercialFiscalYear[]).map((row) => ({
    ...row,
    year: Number(row.year),
  }))
}

export async function previewNextDocumentNumber(params: {
  docType?: string | null
  seriesId?: string | null
  issuedOn?: string | null
}): Promise<string> {
  const { data, error } = await supabase.rpc('preview_next_document_number' as never, {
    p_doc_type: params.docType ?? null,
    p_series_id: params.seriesId ?? null,
    p_issued_on: params.issuedOn ?? null,
  } as never)
  if (error) throw error
  return String(data ?? '')
}

export async function closeCommercialFiscalYear(year: number): Promise<void> {
  const { error } = await supabase.rpc('close_commercial_fiscal_year' as never, {
    p_year: year,
  } as never)
  if (error) throw error
}

export async function reopenCommercialFiscalYear(year: number): Promise<void> {
  const { error } = await supabase.rpc('reopen_commercial_fiscal_year' as never, {
    p_year: year,
  } as never)
  if (error) throw error
}

export type ProjectDeliverySummary = {
  project_id: string
  authorized_cents: number
  billed_cents: number
  advance_pool_cents: number
  unapplied_advance_cents: number
  collected_cents: number
  remaining_cents: number
  has_open_delivery: boolean
}

export async function getProjectDeliverySummary(
  projectId: string,
): Promise<ProjectDeliverySummary | null> {
  const { data, error } = await supabase.rpc('get_project_delivery_summary' as never, {
    p_project_ids: [projectId],
  } as never)
  if (error) throw error
  const row = (Array.isArray(data) ? data[0] : data) as ProjectDeliverySummary | null
  return row ?? null
}

export async function listDeliveryCollectionPage(
  params: ListDeliveryCollectionParams = {},
): Promise<DeliveryCollectionPage> {
  const { data, error } = await supabase.rpc('list_delivery_collection_page' as never, {
    p_client_id: params.clientId || null,
    p_project_id: params.projectId || null,
    p_status_group: params.statusGroup ?? 'open',
    p_has_external_ref: params.hasExternalRef ?? 'all',
    p_q: params.q?.trim() || null,
    p_issued_from: params.issuedFrom || null,
    p_issued_to: params.issuedTo || null,
    p_limit: params.limit ?? 50,
    p_offset: params.offset ?? 0,
  } as never)
  if (error) throw error
  const row = (Array.isArray(data) ? data[0] : data) as {
    items?: DeliveryCollectionRow[] | null
    total_count?: number | string | null
    total_remaining_cents?: number | string | null
  } | null
  return {
    items: (row?.items ?? []) as DeliveryCollectionRow[],
    totalCount: Number(row?.total_count ?? 0),
    totalRemainingCents: Number(row?.total_remaining_cents ?? 0),
  }
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

/** First line name per document, ordered by position. Used as a human title in lists. */
export async function listPrimaryLineNames(
  documentIds: string[],
): Promise<Map<string, string>> {
  const names = new Map<string, string>()
  if (documentIds.length === 0) return names
  const { data, error } = await supabase
    .from('commercial_document_lines' as never)
    .select('document_id, name, position')
    .in('document_id', documentIds)
    .order('position', { ascending: true })
  if (error) throw error
  for (const row of (data ?? []) as Array<{
    document_id: string | null
    name: string | null
  }>) {
    if (!row.document_id || names.has(row.document_id)) continue
    const name = row.name?.trim()
    if (name) names.set(row.document_id, name)
  }
  return names
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
  clientId?: string | null
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
    p_client_id: params.clientId || null,
  } as never)
  if (error) throw error
  return (data ?? []) as CommercialDocumentSearchHit[]
}

export type QuoteAgreementState = {
  id: string
  sourceQuoteId: string
  status: string
  versionStatus: string | null
  renderedDocumentId: string | null
}

export async function listQuoteAgreementStates(
  quoteIds: string[],
): Promise<QuoteAgreementState[]> {
  if (quoteIds.length === 0) return []
  const { data, error } = await supabase
    .from('commercial_agreements' as never)
    .select('id, status, source_quote_id, active_version_id')
    .in('source_quote_id', quoteIds)
    .neq('status', 'cancelled')
  if (error) throw error
  const rows = (data ?? []) as Array<{
    id: string
    status: string
    source_quote_id: string
    active_version_id: string | null
  }>
  const versionIds = rows
    .map((row) => row.active_version_id)
    .filter((id): id is string => !!id)
  const versionStatus = new Map<string, string>()
  const renderedDocumentId = new Map<string, string | null>()
  if (versionIds.length > 0) {
    const { data: versions, error: versionError } = await supabase
      .from('commercial_agreement_versions' as never)
      .select('id, status, rendered_document_id')
      .in('id', versionIds)
    if (versionError) throw versionError
    for (const version of (versions ?? []) as Array<{
      id: string
      status: string
      rendered_document_id: string | null
    }>) {
      versionStatus.set(version.id, version.status)
      renderedDocumentId.set(version.id, version.rendered_document_id)
    }
  }
  return rows.map((row) => ({
    id: row.id,
    sourceQuoteId: row.source_quote_id,
    status: row.status,
    versionStatus: row.active_version_id
      ? versionStatus.get(row.active_version_id) ?? null
      : null,
    renderedDocumentId: row.active_version_id
      ? renderedDocumentId.get(row.active_version_id) ?? null
      : null,
  }))
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
  for (const doc of deliveries) {
    if (!doc.project_id) continue
    if (!['issued', 'signed', 'accepted'].includes(doc.status)) continue
    if (remainingCentsForDocument(doc, docs, payments) > 0) {
      result[doc.project_id] = true
    }
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
    .select('id, event_type, occurred_at, channel, payload')
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
    formalization_mode:
      row.formalization_mode === 'separate_agreement' || row.formalization_mode === 'signed_quote'
        ? row.formalization_mode
        : null,
    external_invoice_ref: (row.external_invoice_ref as string | null | undefined) ?? null,
    supersedes_id: (row.supersedes_id as string | null | undefined) ?? null,
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

export type CommercialAgreementKind = 'specific' | 'recurring' | 'framework'

export async function prepareAgreementFromQuote(params: {
  documentId: string
  templateId: string
  workGate?: 'none' | 'require_signed_agreement'
  clientOpId?: string
  kind?: CommercialAgreementKind
  startsOn?: string | null
  endsOn?: string | null
  noticeDays?: number | null
  autoRenew?: boolean
  slaResponseHours?: number | null
  slaResolutionHours?: number | null
  slaCoverageNotes?: string | null
  billingCadence?: 'none' | 'monthly' | 'quarterly' | 'yearly'
  billingAmountCents?: number | null
  billingCurrency?: string | null
  billingAnchorDay?: number | null
}): Promise<string> {
  const { data, error } = await supabase.rpc('prepare_agreement_from_quote' as never, {
    p_document_id: params.documentId,
    p_template_id: params.templateId,
    p_work_gate: params.workGate ?? 'none',
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
    p_kind: params.kind ?? 'specific',
    p_starts_on: params.startsOn?.trim() || null,
    p_ends_on: params.endsOn?.trim() || null,
    p_notice_days: params.noticeDays ?? null,
    p_auto_renew: params.autoRenew ?? false,
    p_sla_response_hours: params.slaResponseHours ?? null,
    p_sla_resolution_hours: params.slaResolutionHours ?? null,
    p_sla_coverage_notes: params.slaCoverageNotes?.trim() || null,
    p_billing_cadence: params.billingCadence ?? 'none',
    p_billing_amount_cents: params.billingAmountCents ?? null,
    p_billing_currency: params.billingCurrency?.trim() || 'EUR',
    p_billing_anchor_day: params.billingAnchorDay ?? null,
  } as never)
  if (error) throw error
  return data as string
}

export async function createFrameworkAgreement(params: {
  tenantId: string
  clientId: string
  templateId: string
  workGate?: 'none' | 'require_signed_agreement'
  clientOpId?: string
  startsOn?: string | null
  endsOn: string
  noticeDays?: number | null
  locale?: string | null
  autoRenew?: boolean
  slaResponseHours?: number | null
  slaResolutionHours?: number | null
  slaCoverageNotes?: string | null
  billingCadence?: 'none' | 'monthly' | 'quarterly' | 'yearly'
  billingAmountCents?: number | null
  billingCurrency?: string | null
  billingAnchorDay?: number | null
}): Promise<string> {
  const { data, error } = await supabase.rpc('create_framework_agreement' as never, {
    p_tenant_id: params.tenantId,
    p_client_id: params.clientId,
    p_template_id: params.templateId,
    p_work_gate: params.workGate ?? 'none',
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
    p_starts_on: params.startsOn?.trim() || null,
    p_ends_on: params.endsOn.trim(),
    p_notice_days: params.noticeDays ?? null,
    p_locale: params.locale?.trim() || null,
    p_auto_renew: params.autoRenew ?? false,
    p_sla_response_hours: params.slaResponseHours ?? null,
    p_sla_resolution_hours: params.slaResolutionHours ?? null,
    p_sla_coverage_notes: params.slaCoverageNotes?.trim() || null,
    p_billing_cadence: params.billingCadence ?? 'none',
    p_billing_amount_cents: params.billingAmountCents ?? null,
    p_billing_currency: params.billingCurrency?.trim() || 'EUR',
    p_billing_anchor_day: params.billingAnchorDay ?? null,
  } as never)
  if (error) throw error
  return data as string
}

/** @deprecated CF-21-h2: finalize is service_role / signing-hook only. Do not call from the portal. */
export async function finalizeCommercialAgreementVersion(_params: {
  versionId: string
  signedDocumentId?: string | null
  asOf?: string | null
}): Promise<string> {
  throw new Error(
    'finalize_commercial_agreement_version is internal (signing webhook / service_role only)',
  )
}

export async function markAgreementSentForSignature(params: {
  versionId: string
  submissionId: string | null
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('mark_agreement_sent_for_signature' as never, {
    p_version_id: params.versionId,
    p_submission_id: params.submissionId,
    p_signer_role: 'client',
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
  return data as string
}

export async function linkAgreementProject(params: {
  agreementId: string
  projectId: string
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('link_agreement_project' as never, {
    p_agreement_id: params.agreementId,
    p_project_id: params.projectId,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
  return data as string
}

export async function unlinkAgreementProject(params: {
  agreementId: string
  projectId: string
  clientOpId?: string
}): Promise<void> {
  const { error } = await supabase.rpc('unlink_agreement_project' as never, {
    p_agreement_id: params.agreementId,
    p_project_id: params.projectId,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
}

export type AgreementCoverageEntityType = 'contact' | 'contact_site' | 'asset'

export type AgreementCoverageRow = {
  id: string
  agreementId: string
  entityType: AgreementCoverageEntityType
  entityId: string
  label: string
}

export type AgreementMaintenancePlanRow = {
  id: string
  agreementId: string
  maintenancePlanId: string
  planName: string
}

export async function linkAgreementCoverage(params: {
  agreementId: string
  entityType: AgreementCoverageEntityType
  entityId: string
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('link_agreement_coverage' as never, {
    p_agreement_id: params.agreementId,
    p_entity_type: params.entityType,
    p_entity_id: params.entityId,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
  return data as string
}

export async function unlinkAgreementCoverage(params: {
  agreementId: string
  entityType: AgreementCoverageEntityType
  entityId: string
  clientOpId?: string
}): Promise<void> {
  const { error } = await supabase.rpc('unlink_agreement_coverage' as never, {
    p_agreement_id: params.agreementId,
    p_entity_type: params.entityType,
    p_entity_id: params.entityId,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
}

export async function linkAgreementMaintenancePlan(params: {
  agreementId: string
  maintenancePlanId: string
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('link_agreement_maintenance_plan' as never, {
    p_agreement_id: params.agreementId,
    p_maintenance_plan_id: params.maintenancePlanId,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
  return data as string
}

export async function unlinkAgreementMaintenancePlan(params: {
  agreementId: string
  maintenancePlanId: string
  clientOpId?: string
}): Promise<void> {
  const { error } = await supabase.rpc('unlink_agreement_maintenance_plan' as never, {
    p_agreement_id: params.agreementId,
    p_maintenance_plan_id: params.maintenancePlanId,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
}

export async function listAgreementCoverage(
  agreementId: string,
): Promise<AgreementCoverageRow[]> {
  const { data, error } = await supabase
    .from('commercial_agreement_coverage' as never)
    .select('id, agreement_id, entity_type, entity_id')
    .eq('agreement_id', agreementId)
  if (error) throw error
  const rows = (data ?? []) as Array<{
    id: string
    agreement_id: string
    entity_type: AgreementCoverageEntityType
    entity_id: string
  }>
  if (rows.length === 0) return []

  const byType = {
    contact: rows.filter((r) => r.entity_type === 'contact').map((r) => r.entity_id),
    contact_site: rows.filter((r) => r.entity_type === 'contact_site').map((r) => r.entity_id),
    asset: rows.filter((r) => r.entity_type === 'asset').map((r) => r.entity_id),
  }
  const labels = new Map<string, string>()

  if (byType.contact.length > 0) {
    const { data: contacts, error: contactError } = await supabase
      .from('contacts')
      .select('id, display_name')
      .in('id', byType.contact)
    if (contactError) throw contactError
    for (const c of (contacts ?? []) as Array<{ id: string; display_name: string | null }>) {
      labels.set(`contact:${c.id}`, c.display_name?.trim() || c.id.slice(0, 8))
    }
  }
  if (byType.contact_site.length > 0) {
    const { data: sites, error: siteError } = await supabase
      .from('contact_sites')
      .select('id, name')
      .in('id', byType.contact_site)
    if (siteError) throw siteError
    for (const s of (sites ?? []) as Array<{ id: string; name: string | null }>) {
      labels.set(`contact_site:${s.id}`, s.name?.trim() || s.id.slice(0, 8))
    }
  }
  if (byType.asset.length > 0) {
    const { data: assets, error: assetError } = await supabase
      .from('assets')
      .select('id, name')
      .in('id', byType.asset)
    if (assetError) throw assetError
    for (const a of (assets ?? []) as Array<{ id: string; name: string | null }>) {
      labels.set(`asset:${a.id}`, a.name?.trim() || a.id.slice(0, 8))
    }
  }

  return rows.map((row) => ({
    id: row.id,
    agreementId: row.agreement_id,
    entityType: row.entity_type,
    entityId: row.entity_id,
    label: labels.get(`${row.entity_type}:${row.entity_id}`) ?? row.entity_id.slice(0, 8),
  }))
}

export async function listAgreementMaintenancePlans(
  agreementId: string,
): Promise<AgreementMaintenancePlanRow[]> {
  const { data, error } = await supabase
    .from('commercial_agreement_maintenance_plans' as never)
    .select('id, agreement_id, maintenance_plan_id')
    .eq('agreement_id', agreementId)
  if (error) throw error
  const rows = (data ?? []) as Array<{
    id: string
    agreement_id: string
    maintenance_plan_id: string
  }>
  if (rows.length === 0) return []
  const planIds = rows.map((r) => r.maintenance_plan_id)
  const { data: plans, error: planError } = await supabase
    .from('maintenance_plans')
    .select('id, name')
    .in('id', planIds)
  if (planError) throw planError
  const nameById = new Map(
    ((plans ?? []) as Array<{ id: string; name: string | null }>).map((p) => [
      p.id,
      p.name?.trim() || p.id.slice(0, 8),
    ]),
  )
  return rows.map((row) => ({
    id: row.id,
    agreementId: row.agreement_id,
    maintenancePlanId: row.maintenance_plan_id,
    planName: nameById.get(row.maintenance_plan_id) ?? row.maintenance_plan_id.slice(0, 8),
  }))
}

export async function getProjectCommercialInclusion(
  projectId: string,
): Promise<CommercialInclusion> {
  const { data, error } = await supabase.rpc(
    'get_project_commercial_inclusion' as never,
    { p_project_id: projectId } as never,
  )
  if (error) throw error
  return parseCommercialInclusion(data)
}

export async function countAgreementCoverageAndPlans(
  agreementIds: string[],
): Promise<Map<string, { coverage: number; plans: number }>> {
  const out = new Map<string, { coverage: number; plans: number }>()
  if (agreementIds.length === 0) return out
  for (const id of agreementIds) out.set(id, { coverage: 0, plans: 0 })

  const [coverageResult, plansResult] = await Promise.all([
    supabase
      .from('commercial_agreement_coverage' as never)
      .select('agreement_id')
      .in('agreement_id', agreementIds),
    supabase
      .from('commercial_agreement_maintenance_plans' as never)
      .select('agreement_id')
      .in('agreement_id', agreementIds),
  ])
  if (coverageResult.error) throw coverageResult.error
  if (plansResult.error) throw plansResult.error

  for (const row of (coverageResult.data ?? []) as Array<{ agreement_id: string }>) {
    const current = out.get(row.agreement_id) ?? { coverage: 0, plans: 0 }
    current.coverage += 1
    out.set(row.agreement_id, current)
  }
  for (const row of (plansResult.data ?? []) as Array<{ agreement_id: string }>) {
    const current = out.get(row.agreement_id) ?? { coverage: 0, plans: 0 }
    current.plans += 1
    out.set(row.agreement_id, current)
  }
  return out
}

export async function renderCommercialAgreementPdf(params: {
  versionId: string
  tenantId: string
}): Promise<CommercialRenderResult> {
  const { data, error } = await supabase.functions.invoke('render-commercial-agreement', {
    headers: { 'x-tenant-id': params.tenantId },
    body: { version_id: params.versionId },
  })
  if (error) {
    const detailed = await getFunctionErrorMessage(error)
    throw new Error(detailed ?? error.message)
  }
  const payload = (data ?? {}) as Record<string, unknown>
  if (payload.status === 'unavailable' || payload.status === 'error') {
    const errObj = payload.error
    const message =
      typeof errObj === 'string'
        ? errObj
        : errObj && typeof errObj === 'object' && typeof (errObj as { message?: unknown }).message === 'string'
          ? String((errObj as { message: string }).message)
          : payload.status === 'unavailable'
            ? 'gotenberg_unavailable'
            : 'render_failed'
    throw new Error(message)
  }
  return {
    status: 'ready',
    rendered_document_id: (payload.rendered_document_id as string | null | undefined) ?? null,
    version_id: (payload.version_id as string | null | undefined) ?? null,
    download_url: (payload.download_url as string | null | undefined) ?? null,
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

export type AgreementBillingPeriodStatus = 'due' | 'invoiced' | 'skipped' | 'cancelled'

export type AgreementListPageRow = {
  id: string
  kind: string
  status: string
  clientId: string
  sourceQuoteId: string | null
  activeVersionId: string | null
  workGate: string | null
  createdAt: string
  versionStatus: string | null
  renderedDocumentId: string | null
  signedDocumentId: string | null
  fullBodyTemplateId: string | null
  startsOn: string | null
  endsOn: string | null
  noticeDays: number | null
  autoRenew: boolean
  slaResponseHours: number | null
  slaResolutionHours: number | null
  slaCoverageNotes: string | null
  billingCadence: string | null
  billingAmountCents: number | null
  billingCurrency: string | null
  billingAnchorDay: number | null
  cycleId: string | null
  cycleNo: number | null
  cycleStatus: string | null
  cycleStartsOn: string | null
  cycleEndsOn: string | null
  nextBillingOn: string | null
}

export type AgreementsListCursor = { createdAt: string; id: string }

export type AgreementsListPage = {
  rows: AgreementListPageRow[]
  nextCursor: AgreementsListCursor | null
}

export const AGREEMENTS_PAGE_SIZE = 50

function mapAgreementListRow(row: Record<string, unknown>): AgreementListPageRow {
  return {
    id: String(row.id),
    kind: String(row.kind ?? 'specific'),
    status: String(row.status ?? ''),
    clientId: String(row.client_id),
    sourceQuoteId: (row.source_quote_id as string | null) ?? null,
    activeVersionId: (row.active_version_id as string | null) ?? null,
    workGate: (row.work_gate as string | null) ?? null,
    createdAt: String(row.created_at),
    versionStatus: (row.version_status as string | null) ?? null,
    renderedDocumentId: (row.rendered_document_id as string | null) ?? null,
    signedDocumentId: (row.signed_document_id as string | null) ?? null,
    fullBodyTemplateId: (row.full_body_template_id as string | null) ?? null,
    startsOn: (row.starts_on as string | null) ?? null,
    endsOn: (row.ends_on as string | null) ?? null,
    noticeDays: row.notice_days == null ? null : Number(row.notice_days),
    autoRenew: Boolean(row.auto_renew),
    slaResponseHours: row.sla_response_hours == null ? null : Number(row.sla_response_hours),
    slaResolutionHours: row.sla_resolution_hours == null ? null : Number(row.sla_resolution_hours),
    slaCoverageNotes: (row.sla_coverage_notes as string | null) ?? null,
    billingCadence: (row.billing_cadence as string | null) ?? null,
    billingAmountCents: row.billing_amount_cents == null ? null : Number(row.billing_amount_cents),
    billingCurrency: (row.billing_currency as string | null) ?? null,
    billingAnchorDay: row.billing_anchor_day == null ? null : Number(row.billing_anchor_day),
    cycleId: (row.cycle_id as string | null) ?? null,
    cycleNo: row.cycle_no == null ? null : Number(row.cycle_no),
    cycleStatus: (row.cycle_status as string | null) ?? null,
    cycleStartsOn: (row.cycle_starts_on as string | null) ?? null,
    cycleEndsOn: (row.cycle_ends_on as string | null) ?? null,
    nextBillingOn: (row.next_billing_on as string | null) ?? null,
  }
}

export async function listCommercialAgreementsPage(params: {
  limit?: number
  cursor?: AgreementsListCursor | null
  signatureFilter?: 'all' | 'draft' | 'pending' | 'signed' | null
  validityFilter?: 'all' | 'active' | 'expiring' | 'finished' | null
}): Promise<AgreementsListPage> {
  const limit = Math.min(Math.max(params.limit ?? AGREEMENTS_PAGE_SIZE, 1), 199)
  const { data, error } = await supabase.rpc('list_commercial_agreements_page' as never, {
    p_limit: limit + 1,
    p_cursor_created_at: params.cursor?.createdAt ?? null,
    p_cursor_id: params.cursor?.id ?? null,
    p_signature_filter: params.signatureFilter ?? 'all',
    p_validity_filter: params.validityFilter ?? 'all',
  } as never)
  if (error) throw error
  const all = ((data ?? []) as Array<Record<string, unknown>>).map(mapAgreementListRow)
  const rows = all.slice(0, limit)
  const last = rows[rows.length - 1]
  return {
    rows,
    nextCursor: all.length > limit && last ? { createdAt: last.createdAt, id: last.id } : null,
  }
}

export async function cancelCommercialAgreement(params: {
  agreementId: string
  reason?: string | null
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('cancel_commercial_agreement' as never, {
    p_agreement_id: params.agreementId,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
    p_reason: params.reason ?? null,
  } as never)
  if (error) throw error
  return data as string
}

export async function suspendCommercialAgreement(params: {
  agreementId: string
  reason?: string | null
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('suspend_commercial_agreement' as never, {
    p_agreement_id: params.agreementId,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
    p_reason: params.reason ?? null,
  } as never)
  if (error) throw error
  return data as string
}

export async function resumeCommercialAgreement(params: {
  agreementId: string
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc('resume_commercial_agreement' as never, {
    p_agreement_id: params.agreementId,
    p_client_op_id: params.clientOpId ?? generateClientOpId(),
  } as never)
  if (error) throw error
  return data as string
}

export async function sendAgreementVersionForSignature(params: {
  versionId: string
  tenantId: string
  documentTitle: string
  signerName: string
}): Promise<string> {
  const rendered = await renderCommercialAgreementPdf({
    versionId: params.versionId,
    tenantId: params.tenantId,
  })
  if (!rendered.version_id) throw new Error('agreement_pdf_required')
  const { callSignDocumentRouter } = await import('@/features/signing/api/signingService')
  const opId = generateClientOpId()
  const result = await callSignDocumentRouter({
    tenant_id: params.tenantId,
    action: 'sign_native',
    source_type: 'document_existing',
    source_document_version_id: rendered.version_id,
    document_title: params.documentTitle,
    native_sign_type: 'presential',
    output_format: 'pdf',
    output_profile: 'pdfa2b',
    signer_name: params.signerName,
    signer_role: 'client',
    client_request_id: opId,
  })
  return markAgreementSentForSignature({
    versionId: params.versionId,
    submissionId: result.submission_id ?? null,
    clientOpId: opId,
  })
}

export async function hasRecentAgreementSigningFailure(agreementId: string): Promise<boolean> {
  const { data, error } = await supabase
    .from('commercial_agreement_events' as never)
    .select('id')
    .eq('agreement_id', agreementId)
    .eq('event_type', 'signing_failed')
    .order('created_at', { ascending: false })
    .limit(1)
  if (error) throw error
  return ((data ?? []) as unknown[]).length > 0
}

export type AgreementBillingPeriodRow = {
  id: string
  agreementId: string
  periodStart: string
  periodEnd: string
  dueOn: string
  amountCents: number
  currency: string
  status: AgreementBillingPeriodStatus
  externalInvoiceRef: string | null
  notes: string | null
}

function mapBillingPeriodRow(row: Record<string, unknown>): AgreementBillingPeriodRow {
  return {
    id: String(row.id),
    agreementId: String(row.agreement_id),
    periodStart: String(row.period_start),
    periodEnd: String(row.period_end),
    dueOn: String(row.due_on),
    amountCents: Number(row.amount_cents ?? 0),
    currency: String(row.currency ?? 'EUR'),
    status: row.status as AgreementBillingPeriodStatus,
    externalInvoiceRef: (row.external_invoice_ref as string | null) ?? null,
    notes: (row.notes as string | null) ?? null,
  }
}

export const AGREEMENT_BILLING_PERIODS_PAGE_SIZE = 24

export type AgreementBillingPeriodsCursor = { dueOn: string; id: string }

export type AgreementBillingPeriodsPage = {
  rows: AgreementBillingPeriodRow[]
  nextCursor: AgreementBillingPeriodsCursor | null
}

/** CF-21-h7: keyset page (due_on DESC, id DESC). Fetches limit + 1 rows to know if there is more. */
export async function listAgreementBillingPeriodsPage(params: {
  agreementId: string
  limit?: number
  cursor?: AgreementBillingPeriodsCursor | null
}): Promise<AgreementBillingPeriodsPage> {
  const limit = Math.min(Math.max(params.limit ?? AGREEMENT_BILLING_PERIODS_PAGE_SIZE, 1), 199)
  const { data, error } = await supabase.rpc('list_agreement_billing_periods_page' as never, {
    p_agreement_id: params.agreementId,
    p_limit: limit + 1,
    p_cursor_due_on: params.cursor?.dueOn ?? null,
    p_cursor_id: params.cursor?.id ?? null,
  } as never)
  if (error) throw error
  const all = ((data ?? []) as Array<Record<string, unknown>>).map(mapBillingPeriodRow)
  const rows = all.slice(0, limit)
  const last = rows[rows.length - 1]
  return {
    rows,
    nextCursor: all.length > limit && last ? { dueOn: last.dueOn, id: last.id } : null,
  }
}

/**
 * Unbounded convenience wrapper (kept for callers that need every period). The UI uses
 * {@link listAgreementBillingPeriodsPage}.
 */
export async function listAgreementBillingPeriods(
  agreementId: string,
): Promise<AgreementBillingPeriodRow[]> {
  const out: AgreementBillingPeriodRow[] = []
  let cursor: AgreementBillingPeriodsCursor | null = null
  for (let guard = 0; guard < 50; guard += 1) {
    const page = await listAgreementBillingPeriodsPage({ agreementId, limit: 199, cursor })
    out.push(...page.rows)
    if (!page.nextCursor) break
    cursor = page.nextCursor
  }
  return out
}

export async function markAgreementBillingPeriodInvoiced(params: {
  periodId: string
  externalInvoiceRef: string
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc(
    'mark_agreement_billing_period_invoiced' as never,
    {
      p_period_id: params.periodId,
      p_external_invoice_ref: params.externalInvoiceRef,
      p_client_op_id: params.clientOpId ?? generateClientOpId(),
    } as never,
  )
  if (error) throw error
  return data as string
}

export async function skipAgreementBillingPeriod(params: {
  periodId: string
  notes?: string | null
  clientOpId?: string
}): Promise<string> {
  const { data, error } = await supabase.rpc(
    'skip_agreement_billing_period' as never,
    {
      p_period_id: params.periodId,
      p_client_op_id: params.clientOpId ?? generateClientOpId(),
      p_notes: params.notes?.trim() || null,
    } as never,
  )
  if (error) throw error
  return data as string
}

