import { supabase } from '@/lib/supabase'
import type { Json } from '@/types/database.types'
import {
  getContact,
  listContactDeliveryChannels,
  listContactDeliveryRules,
  listContactRelationships,
} from '@/features/contacts/api/contactsService'
import type {
  ContactDeliveryChannel,
  ContactDeliveryRule,
  ContactRelationship,
} from '@/features/contacts/api/contactsService'
import { buildPublicReport } from './checklistTemplatesService'

export type CirReport = {
  id: string
  tenant_id: string
  project_id: string
  report_type: string
  current_published_version_id: string | null
  legacy_unresolved: boolean
  created_at: string
  updated_at: string
}

export type BulletinContentSelection = {
  checklist_run_item_ids: string[]
  task_ids: string[]
  material_ids: string[]
  checklist_seeded?: boolean
  tasks_seeded?: boolean
  materials_seeded?: boolean
  /** Media file_node_ids the user explicitly removed after auto-include. */
  media_excluded_ids?: string[]
}

export type BulletinChecklistCandidate = {
  id: string
  run_item_id?: string
  run_id?: string
  run_name?: string | null
  title?: string | null
  note?: string | null
  include_in_report?: boolean
  option_semantics?: string | null
  option_label?: string | null
  value_bool?: boolean | null
  response_type?: string | null
  description_public?: string | null
  [key: string]: unknown
}

export type BulletinTaskCandidate = {
  id: string
  title?: string | null
  status?: string | null
  due_date?: string | null
  notes_html?: string | null
  position?: number | null
  [key: string]: unknown
}

export type BulletinMaterialCandidate = {
  id: string
  name?: string | null
  quantity?: number | null
  unit?: string | null
  [key: string]: unknown
}

export type BulletinContentCandidates = {
  checklist_items: BulletinChecklistCandidate[]
  tasks: BulletinTaskCandidate[]
  materials: BulletinMaterialCandidate[]
  tenant_show_checklists: boolean
  tenant_show_tasks: boolean
  tenant_show_materials: boolean
}

export type CirDraft = {
  id: string
  report_id: string
  project_id: string
  status: 'draft' | 'preparing_media' | 'ready' | 'failed' | 'superseded'
  customer_account_contact_id: string | null
  locale: string
  client_summary_html: string | null
  projection: Json
  selected_media: Json
  media_manifest: Json
  failure_reason: string | null
  updated_at: string
  show_checklists?: boolean | null
  show_tasks?: boolean | null
  show_materials?: boolean | null
  content_selection?: Json
}

export type CirVersion = {
  id: string
  report_id: string
  project_id: string
  version_number: number
  locale: string
  content_digest: string
  projection: Json
  media_manifest: Json
  published_at: string
  published_by: string | null
  customer_account_contact_id: string | null
  show_checklists?: boolean | null
  show_tasks?: boolean | null
  show_materials?: boolean | null
  content_selection?: Json
}

export type CustomerReportShare = {
  id: string
  project_id: string
  report_id: string
  report_version_id: string
  customer_account_contact_id: string
  recipient_contact_id: string | null
  channel: 'manual_link' | 'email'
  expires_at: string
  session_count: number
  view_count: number
  created_at: string
  revoked_at: string | null
  revoke_reason: string | null
  is_active: boolean | null
}

export type CreateShareResult = {
  share_id: string
  secret: string
  expires_at: string
  report_version_id: string
  channel: string
}

export type AccountDeliveryOptions = {
  relationships: ContactRelationship[]
  channelsByContact: Record<string, ContactDeliveryChannel[]>
  rules: ContactDeliveryRule[]
  accountChannels: ContactDeliveryChannel[]
}

function normalizeSelectedMedia(selectedMedia: Json): Json {
  if (!Array.isArray(selectedMedia)) {
    throw new Error('selected_media_must_be_array')
  }

  return selectedMedia
    .filter((item) => {
      const record =
        item && typeof item === 'object' && !Array.isArray(item)
          ? (item as Record<string, Json | undefined>)
          : null
      return record?.include !== false
    })
    .map((item) => {
      const record = item as Record<string, Json | undefined>
      const fileNodeId = typeof record.file_node_id === 'string' ? record.file_node_id.trim() : ''
      if (!fileNodeId) {
        throw new Error('file_node_id_required')
      }
      return { file_node_id: fileNodeId }
    }) as Json
}

function customerPortalOrigin(): string {
  const base = (import.meta.env.VITE_CUSTOMER_PORTAL_ORIGIN as string | undefined)?.replace(
    /\/$/,
    '',
  )
  if (!base) {
    throw new Error('VITE_CUSTOMER_PORTAL_ORIGIN is required to build customer portal URLs')
  }
  return base
}

function customerPortalShareUrl(secret: string): string {
  return `${customerPortalOrigin()}/s/${secret}`
}

export { customerPortalShareUrl, customerPortalOrigin }

export async function getCirReportForProject(projectId: string): Promise<CirReport | null> {
  const { data, error } = await supabase
    .from('customer_intervention_reports')
    .select('*')
    .eq('project_id', projectId)
    .maybeSingle()
  if (error) throw error
  return (data as CirReport | null) ?? null
}

export async function ensureCirReport(projectId: string): Promise<string> {
  const { data, error } = await supabase.rpc('ensure_customer_intervention_report', {
    p_project_id: projectId,
  })
  if (error) throw error
  return data as string
}

export async function getActiveCirDraft(reportId: string): Promise<CirDraft | null> {
  const { data, error } = await supabase
    .from('customer_intervention_report_drafts')
    .select('*')
    .eq('report_id', reportId)
    .in('status', ['draft', 'preparing_media', 'ready', 'failed'])
    .order('updated_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) throw error
  return (data as CirDraft | null) ?? null
}

export async function getCirVersion(versionId: string): Promise<CirVersion | null> {
  const { data, error } = await supabase
    .from('customer_intervention_report_versions')
    .select('*')
    .eq('id', versionId)
    .maybeSingle()
  if (error) throw error
  return (data as CirVersion | null) ?? null
}

export async function listCirVersions(reportId: string): Promise<CirVersion[]> {
  const { data, error } = await supabase
    .from('customer_intervention_report_versions')
    .select('*')
    .eq('report_id', reportId)
    .order('version_number', { ascending: false })
  if (error) throw error
  return (data ?? []) as CirVersion[]
}

export async function listProjectShares(projectId: string): Promise<CustomerReportShare[]> {
  const { data, error } = await supabase.rpc('list_customer_report_shares' as any, {
    p_project_id: projectId,
  })
  if (error) throw error
  return (data ?? []) as CustomerReportShare[]
}

function verifiedChannels(channels: ContactDeliveryChannel[]): ContactDeliveryChannel[] {
  return channels.filter((c) => Boolean(c.verified_at) || Boolean(c.is_verified))
}

/** Delivery options for a client account (company or person): channels, relationships, bulletin rules. */
export async function listAccountDeliveryOptions(
  accountContactId: string,
): Promise<AccountDeliveryOptions> {
  const account = await getContact(accountContactId)
  const accountChannels = verifiedChannels(
    await listContactDeliveryChannels(accountContactId, { activeOnly: true }),
  )

  let relationships: ContactRelationship[] = []
  if (account?.kind === 'company') {
    relationships = await listContactRelationships({
      organizationContactId: accountContactId,
      activeOnly: true,
    })
  }

  const channelsByContact: Record<string, ContactDeliveryChannel[]> = {
    [accountContactId]: accountChannels,
  }

  await Promise.all(
    relationships.map(async (rel) => {
      const channels = await listContactDeliveryChannels(rel.person_contact_id, {
        activeOnly: true,
      })
      channelsByContact[rel.person_contact_id] = verifiedChannels(channels)
    }),
  )

  const rules = await listContactDeliveryRules(accountContactId, {
    activeOnly: true,
    purpose: 'bulletin',
  })

  return { relationships, channelsByContact, rules, accountChannels }
}

export function parseContentSelection(raw: unknown): BulletinContentSelection {
  const o = raw && typeof raw === 'object' && !Array.isArray(raw)
    ? (raw as Record<string, unknown>)
    : {}
  const asIds = (v: unknown): string[] =>
    Array.isArray(v)
      ? v.filter((x): x is string => typeof x === 'string' && x.length > 0)
      : []
  return {
    checklist_run_item_ids: asIds(o.checklist_run_item_ids),
    task_ids: asIds(o.task_ids),
    material_ids: asIds(o.material_ids),
    checklist_seeded: o.checklist_seeded === true,
    tasks_seeded: o.tasks_seeded === true,
    materials_seeded: o.materials_seeded === true,
    media_excluded_ids: asIds(o.media_excluded_ids),
  }
}

/** Merge new candidates into selection without wiping prior choices. */
export function seedOrMergeContentSelection(
  existing: BulletinContentSelection | null | undefined,
  candidates: BulletinContentCandidates,
): BulletinContentSelection {
  const prev = existing ?? {
    checklist_run_item_ids: [],
    task_ids: [],
    material_ids: [],
    checklist_seeded: false,
    tasks_seeded: false,
    materials_seeded: false,
    media_excluded_ids: [],
  }

  const knownChecklist = new Set(candidates.checklist_items.map((i) => String(i.id)))
  const knownTasks = new Set(candidates.tasks.map((t) => String(t.id)))
  const knownMaterials = new Set(candidates.materials.map((m) => String(m.id)))

  let checklistIds = prev.checklist_run_item_ids.filter((id) => knownChecklist.has(id))
  let taskIds = prev.task_ids.filter((id) => knownTasks.has(id))
  let materialIds = prev.material_ids.filter((id) => knownMaterials.has(id))

  if (!prev.checklist_seeded) {
    checklistIds = candidates.checklist_items
      .filter((i) => i.include_in_report === true)
      .map((i) => String(i.id))
  } else {
    const prevSet = new Set(prev.checklist_run_item_ids)
    for (const item of candidates.checklist_items) {
      const id = String(item.id)
      if (!prevSet.has(id) && !checklistIds.includes(id) && item.include_in_report === true) {
        checklistIds.push(id)
      }
    }
  }

  if (!prev.tasks_seeded) {
    taskIds = candidates.tasks.map((t) => String(t.id))
  } else {
    const prevSet = new Set(prev.task_ids)
    // Keep prior inclusions that still exist; newly appeared tasks default on.
    for (const task of candidates.tasks) {
      const id = String(task.id)
      if (!prevSet.has(id) && !taskIds.includes(id)) {
        taskIds.push(id)
      }
    }
  }

  if (!prev.materials_seeded) {
    materialIds = candidates.materials.map((m) => String(m.id))
  } else {
    const prevSet = new Set(prev.material_ids)
    for (const material of candidates.materials) {
      const id = String(material.id)
      if (!prevSet.has(id) && !materialIds.includes(id)) {
        materialIds.push(id)
      }
    }
  }

  return {
    checklist_run_item_ids: checklistIds,
    task_ids: taskIds,
    material_ids: materialIds,
    checklist_seeded: true,
    tasks_seeded: true,
    materials_seeded: true,
    media_excluded_ids: prev.media_excluded_ids ?? [],
  }
}

export function resolveBulletinShowFlags(params: {
  draftShowChecklists?: boolean | null
  draftShowTasks?: boolean | null
  draftShowMaterials?: boolean | null
  tenantShowChecklists: boolean
  tenantShowTasks: boolean
  tenantShowMaterials: boolean
}): {
  showChecklists: boolean
  showTasks: boolean
  showMaterials: boolean
  checklistsInherited: boolean
  tasksInherited: boolean
  materialsInherited: boolean
} {
  const checklistsInherited = params.draftShowChecklists == null
  const tasksInherited = params.draftShowTasks == null
  const materialsInherited = params.draftShowMaterials == null
  return {
    showChecklists: params.draftShowChecklists ?? params.tenantShowChecklists,
    showTasks: params.draftShowTasks ?? params.tenantShowTasks,
    showMaterials: params.draftShowMaterials ?? params.tenantShowMaterials,
    checklistsInherited,
    tasksInherited,
    materialsInherited,
  }
}

function mapChecklistItemForProjection(item: BulletinChecklistCandidate): Record<string, unknown> {
  return {
    id: item.id,
    run_item_id: item.run_item_id ?? item.id,
    run_id: item.run_id,
    run_name: item.run_name,
    title: item.title,
    description_public: item.description_public ?? '',
    note: item.note,
    option_label: item.option_label,
    option_semantics: item.option_semantics,
    value_bool: item.value_bool,
    response_type: item.response_type ?? null,
  }
}

function mapTaskForProjection(task: BulletinTaskCandidate): Record<string, unknown> {
  return {
    id: task.id,
    title: task.title,
    status: task.status,
    due_date: task.due_date,
    notes_html: task.notes_html,
  }
}

function mapMaterialForProjection(material: BulletinMaterialCandidate): Record<string, unknown> {
  return {
    id: material.id,
    name: material.name,
    quantity: material.quantity,
    unit: material.unit ?? null,
  }
}

export function buildBulletinProjection(params: {
  projectId: string
  locale: string
  candidates: BulletinContentCandidates
  selection: BulletinContentSelection
  showChecklists: boolean
  showTasks: boolean
  showMaterials: boolean
  existingProjection?: Record<string, unknown> | null
}): Json {
  const selectedChecklist = new Set(params.selection.checklist_run_item_ids)
  const selectedTasks = new Set(params.selection.task_ids)
  const selectedMaterials = new Set(params.selection.material_ids)
  const checklist_items = params.showChecklists
    ? params.candidates.checklist_items
        .filter((i) => selectedChecklist.has(String(i.id)))
        .map(mapChecklistItemForProjection)
    : []
  const tasks = params.showTasks
    ? params.candidates.tasks
        .filter((t) => selectedTasks.has(String(t.id)))
        .map(mapTaskForProjection)
    : []
  const materials = params.showMaterials
    ? params.candidates.materials
        .filter((m) => selectedMaterials.has(String(m.id)))
        .map(mapMaterialForProjection)
    : []

  const prev = params.existingProjection ?? {}
  return {
    schema_version: '1.1',
    locale: params.locale,
    tenant: prev.tenant,
    customer_account: prev.customer_account,
    site: prev.site,
    support_contact: prev.support_contact,
    intervention: {
      ...(typeof prev.intervention === 'object' && prev.intervention
        ? (prev.intervention as Record<string, unknown>)
        : {}),
      project_id: params.projectId,
      generated_at: new Date().toISOString(),
    },
    checklist_items,
    tasks,
    materials,
    visibility: {
      show_checklists: params.showChecklists,
      show_tasks: params.showTasks,
      show_materials: params.showMaterials,
    },
  } as Json
}

export async function listBulletinContentCandidates(
  projectId: string,
): Promise<BulletinContentCandidates> {
  const { data, error } = await supabase.rpc(
    'list_project_bulletin_content_candidates' as never,
    { p_project_id: projectId } as never,
  )
  if (error) throw error
  const row = (data && typeof data === 'object' ? data : {}) as Record<string, unknown>
  return {
    checklist_items: Array.isArray(row.checklist_items)
      ? (row.checklist_items as BulletinChecklistCandidate[])
      : [],
    tasks: Array.isArray(row.tasks) ? (row.tasks as BulletinTaskCandidate[]) : [],
    materials: Array.isArray(row.materials)
      ? (row.materials as BulletinMaterialCandidate[])
      : [],
    tenant_show_checklists: row.tenant_show_checklists !== false,
    tenant_show_tasks: row.tenant_show_tasks !== false,
    tenant_show_materials: row.tenant_show_materials !== false,
  }
}

export async function upsertCirDraft(params: {
  projectId: string
  locale?: string
  clientSummaryHtml?: string | null
  draftId?: string | null
  selectedMedia?: Json
  projection?: Json
  showChecklists?: boolean | null
  showTasks?: boolean | null
  showMaterials?: boolean | null
  clearShowChecklists?: boolean
  clearShowTasks?: boolean
  clearShowMaterials?: boolean
  contentSelection?: BulletinContentSelection | Json
  /** @deprecated Prefer explicit projection + contentSelection */
  refreshProjectionFromChecklist?: boolean
}): Promise<string> {
  let projection: Json = params.projection ?? {}

  if (params.projection === undefined && params.refreshProjectionFromChecklist !== false) {
    try {
      const candidates = await listBulletinContentCandidates(params.projectId)
      const selection = seedOrMergeContentSelection(
        params.contentSelection
          ? parseContentSelection(params.contentSelection)
          : null,
        candidates,
      )
      const flags = resolveBulletinShowFlags({
        draftShowChecklists: params.showChecklists,
        draftShowTasks: params.showTasks,
        draftShowMaterials: params.showMaterials,
        tenantShowChecklists: candidates.tenant_show_checklists,
        tenantShowTasks: candidates.tenant_show_tasks,
        tenantShowMaterials: candidates.tenant_show_materials,
      })
      projection = buildBulletinProjection({
        projectId: params.projectId,
        locale: params.locale ?? 'es',
        candidates,
        selection,
        showChecklists: flags.showChecklists,
        showTasks: flags.showTasks,
        showMaterials: flags.showMaterials,
      })
      if (!params.contentSelection) {
        params = { ...params, contentSelection: selection }
      }
    } catch {
      // Fallback: legacy checklist-only builder (include_in_report filter)
      try {
        const legacy = await buildPublicReport(params.projectId, params.locale)
        const p = (legacy && typeof legacy === 'object' ? legacy : {}) as Record<string, unknown>
        projection = {
          schema_version: '1.1',
          locale: p.locale ?? params.locale ?? 'es',
          intervention: {
            project_id: p.project_id ?? params.projectId,
            generated_at: p.generated_at,
          },
          checklist_items: p.checklist_items ?? p.items ?? [],
          tasks: [],
          materials: [],
        } as Json
      } catch {
        projection = {
          schema_version: '1.1',
          checklist_items: [],
          tasks: [],
          materials: [],
        }
      }
    }
  }

  const rpcArgs: Record<string, unknown> = {
    p_project_id: params.projectId,
    p_locale: params.locale ?? 'es',
    p_client_summary_html: params.clientSummaryHtml ?? undefined,
    p_projection: projection,
    p_draft_id: params.draftId ?? undefined,
  }
  if (params.selectedMedia !== undefined) {
    rpcArgs.p_selected_media = normalizeSelectedMedia(params.selectedMedia)
  }
  if (params.clearShowChecklists) {
    rpcArgs.p_clear_show_checklists = true
  } else if (params.showChecklists !== undefined && params.showChecklists !== null) {
    rpcArgs.p_show_checklists = params.showChecklists
  }
  if (params.clearShowTasks) {
    rpcArgs.p_clear_show_tasks = true
  } else if (params.showTasks !== undefined && params.showTasks !== null) {
    rpcArgs.p_show_tasks = params.showTasks
  }
  if (params.clearShowMaterials) {
    rpcArgs.p_clear_show_materials = true
  } else if (params.showMaterials !== undefined && params.showMaterials !== null) {
    rpcArgs.p_show_materials = params.showMaterials
  }
  if (params.contentSelection !== undefined) {
    rpcArgs.p_content_selection = params.contentSelection as Json
  }

  const { data, error } = await supabase.rpc(
    'upsert_customer_intervention_report_draft',
    rpcArgs as never,
  )
  if (error) throw error
  return data as string
}

export async function prepareCirMedia(draftId: string): Promise<Json> {
  const { data, error } = await supabase.rpc('prepare_customer_intervention_report_media', {
    p_draft_id: draftId,
  })
  if (error) throw error
  return data as Json
}

export async function previewCirDraft(draftId: string): Promise<Json> {
  const { data, error } = await supabase.rpc('preview_customer_intervention_report_draft', {
    p_draft_id: draftId,
  })
  if (error) throw error
  return data as Json
}

export async function publishCirDraft(draftId: string): Promise<string> {
  const { data, error } = await supabase.rpc('publish_customer_intervention_report', {
    p_draft_id: draftId,
  })
  if (error) throw error
  return data as string
}

export async function createCorrectedCirDraft(reportId: string): Promise<string> {
  const { data, error } = await supabase.rpc('create_corrected_customer_intervention_report_draft', {
    p_report_id: reportId,
  })
  if (error) throw error
  return data as string
}

/** Prepare media (copy pending → customer-report-media) + publish. */
export async function publishBulletin(params: {
  projectId: string
  clientSummaryHtml?: string | null
  locale?: string
  draftId?: string | null
  selectedMedia?: Json
  showChecklists?: boolean | null
  showTasks?: boolean | null
  showMaterials?: boolean | null
  clearShowChecklists?: boolean
  clearShowTasks?: boolean
  clearShowMaterials?: boolean
  contentSelection?: BulletinContentSelection
  projection?: Json
}): Promise<string> {
  await ensureCirReport(params.projectId)
  const draftId = await upsertCirDraft({
    projectId: params.projectId,
    locale: params.locale,
    clientSummaryHtml: params.clientSummaryHtml,
    draftId: params.draftId,
    selectedMedia: params.selectedMedia,
    showChecklists: params.showChecklists,
    showTasks: params.showTasks,
    showMaterials: params.showMaterials,
    clearShowChecklists: params.clearShowChecklists,
    clearShowTasks: params.clearShowTasks,
    clearShowMaterials: params.clearShowMaterials,
    contentSelection: params.contentSelection,
    projection: params.projection,
    refreshProjectionFromChecklist: params.projection === undefined,
  })
  const prepared = (await prepareCirMedia(draftId)) as {
    status?: string
    pending_count?: number
  }
  const needsCopy =
    prepared?.status === 'preparing_media' ||
    (typeof prepared?.pending_count === 'number' && prepared.pending_count > 0)

  if (needsCopy) {
    const { data, error } = await supabase.functions.invoke('copy-customer-report-media', {
      body: { draft_id: draftId },
    })
    if (error) {
      throw new Error(error.message || 'media_copy_failed')
    }
    const payload = data as { ok?: boolean; error?: { message?: string } } | null
    if (payload && payload.ok === false) {
      throw new Error(payload.error?.message || 'media_copy_failed')
    }
  }

  return publishCirDraft(draftId)
}

export async function createManualShare(params: {
  projectId: string
  recipientContactId?: string | null
  ttlHours?: number
  reportVersionId?: string | null
  deliveryChannelId?: string | null
}): Promise<CreateShareResult & { share_url: string }> {
  const { data, error } = await supabase.rpc('create_customer_report_share' as any, {
    p_project_id: params.projectId,
    p_recipient_contact_id: params.recipientContactId ?? undefined,
    p_ttl_hours: params.ttlHours ?? 72,
    p_report_version_id: params.reportVersionId ?? undefined,
    p_delivery_channel_id: params.deliveryChannelId ?? undefined,
  })
  if (error) throw error
  const result = data as CreateShareResult
  return {
    ...result,
    share_url: customerPortalShareUrl(result.secret),
  }
}

export async function revokeShare(shareId: string, reason?: string): Promise<string> {
  const { data, error } = await supabase.rpc('revoke_customer_report_share' as any, {
    p_share_id: shareId,
    p_reason: reason ?? undefined,
  })
  if (error) throw error
  return data as string
}

export async function enqueueShareEmail(params: {
  projectId: string
  deliveryChannelId: string
  idempotencyKey: string
  ttlHours?: number
  reportVersionId?: string | null
  recipientContactId?: string | null
}): Promise<string> {
  const { data, error } = await supabase.rpc('enqueue_customer_report_share_email' as any, {
    p_project_id: params.projectId,
    p_delivery_channel_id: params.deliveryChannelId,
    p_idempotency_key: params.idempotencyKey,
    p_ttl_hours: params.ttlHours ?? 72,
    p_report_version_id: params.reportVersionId ?? undefined,
    p_recipient_contact_id: params.recipientContactId ?? undefined,
  })
  if (error) throw error
  return data as string
}

export async function createStaffPreviewSession(params: {
  reportVersionId?: string | null
  ttlMinutes?: number
  clientAccountContactId?: string | null
}): Promise<{ secret: string; expires_at: string; preview_url: string }> {
  const { data, error } = await supabase.rpc('create_customer_portal_staff_session' as any, {
    p_report_version_id: params.reportVersionId ?? null,
    p_ttl_minutes: params.ttlMinutes ?? 30,
    p_client_account_contact_id: params.clientAccountContactId ?? null,
  })
  if (error) throw error
  const row = data as { secret: string; expires_at: string }
  return {
    secret: row.secret,
    expires_at: row.expires_at,
    preview_url: `${customerPortalOrigin()}/staff/${row.secret}`,
  }
}
