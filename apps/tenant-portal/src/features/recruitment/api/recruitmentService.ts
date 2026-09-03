import { supabase } from '@/lib/supabase'
import { getFunctionErrorMessage, getResponseErrorMessage } from '@/lib/functionErrors'

export type JobPostingStatus = 'draft' | 'published' | 'unlisted' | 'expired' | 'archived'

export type JobPosting = {
  id: string
  tenant_id: string
  site_id: string | null
  department_id: string | null
  job_position_id: string | null
  location_id: string | null
  title: string
  description: string | null
  interviewer_guide: string | null
  public_slug: string
  status: JobPostingStatus
  opens_at: string | null
  closes_at: string | null
  created_at: string
  updated_at: string
}

export type JobPostingApplicationRow = {
  id: string
  created_at: string
  source: string
  candidate_visible_status: string
  outcome_communicated_at: string | null
  outcome_kind: string | null
  hired_employee_id: string | null
  hired_at: string | null
  purge_at: string
  stage_id: string | null
  job_posting_id?: string
  cv_storage_path: string | null
  retention_preference: string
  retention_months: number | null
  cv_structured: CvStructuredPayload | null
  cv_structured_at: string | null
  applicant: {
    full_name: string
    email: string
    phone: string | null
    email_verified_at: string | null
  } | null
  job_posting?: {
    id: string
    title: string
    status: JobPostingStatus
    job_position_id: string | null
  } | null
}

export type JobPostingSummary = JobPosting & {
  application_count: number
  public_site_count: number
}

export type TenantApplicationsFilters = {
  postingId?: string | null
  jobPositionId?: string | null
  postingStatus?: JobPostingStatus | 'live' | 'all' | null
  search?: string | null
}

export type CvStructuredPayload = {
  skills: string[]
  experience: unknown[]
  education: unknown[]
  languages: unknown[]
}

export type PipelineStage = {
  id: string
  tenant_id: string
  job_posting_id: string | null
  name: string
  position: number
  is_terminal_hire: boolean
  is_terminal_reject: boolean
}

// Tables not yet in generated Database types (REC-1 migration).
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any

export function slugifyTitle(title: string): string {
  return title
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 80) || 'oferta'
}

export async function listJobPostings(): Promise<JobPosting[]> {
  const { data, error } = await db
    .from('job_postings')
    .select('*')
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as JobPosting[]
}

export async function listJobPostingSummaries(): Promise<JobPostingSummary[]> {
  const postings = await listJobPostings()
  if (postings.length === 0) return []

  const ids = postings.map((p) => p.id)
  const [{ data: appRows, error: appErr }, { data: siteRows, error: siteErr }] = await Promise.all([
    db.from('applications').select('job_posting_id').in('job_posting_id', ids),
    db.from('job_posting_public_sites').select('job_posting_id').in('job_posting_id', ids),
  ])
  if (appErr) throw appErr
  if (siteErr) throw siteErr

  const appCounts = new Map<string, number>()
  for (const row of (appRows ?? []) as { job_posting_id: string }[]) {
    appCounts.set(row.job_posting_id, (appCounts.get(row.job_posting_id) ?? 0) + 1)
  }
  const siteCounts = new Map<string, number>()
  for (const row of (siteRows ?? []) as { job_posting_id: string }[]) {
    siteCounts.set(row.job_posting_id, (siteCounts.get(row.job_posting_id) ?? 0) + 1)
  }

  return postings.map((p) => ({
    ...p,
    application_count: appCounts.get(p.id) ?? 0,
    public_site_count: siteCounts.get(p.id) ?? 0,
  }))
}

export async function getJobPosting(id: string): Promise<JobPosting> {
  const { data, error } = await db.from('job_postings').select('*').eq('id', id).single()
  if (error) throw error
  return data as JobPosting
}

export async function listPostingPublicSites(jobPostingId: string): Promise<string[]> {
  const { data, error } = await db
    .from('job_posting_public_sites')
    .select('public_site_id')
    .eq('job_posting_id', jobPostingId)
  if (error) throw error
  return ((data ?? []) as { public_site_id: string }[]).map((r) => r.public_site_id)
}

export type CreateJobPostingParams = {
  tenant_id: string
  title: string
  description?: string | null
  public_slug?: string
  status?: JobPostingStatus
  site_id?: string | null
  department_id?: string | null
  job_position_id?: string | null
  public_site_ids?: string[]
}

export async function createJobPosting(params: CreateJobPostingParams): Promise<JobPosting> {
  const slug = params.public_slug?.trim() || slugifyTitle(params.title)
  const { data, error } = await db
    .from('job_postings')
    .insert({
      tenant_id: params.tenant_id,
      title: params.title.trim(),
      description: params.description ?? null,
      public_slug: slug,
      status: params.status ?? 'draft',
      site_id: params.site_id ?? null,
      department_id: params.department_id ?? null,
      job_position_id: params.job_position_id ?? null,
    })
    .select('*')
    .single()
  if (error) throw error
  const posting = data as JobPosting

  if (params.public_site_ids?.length) {
    const rows = params.public_site_ids.map((public_site_id) => ({
      job_posting_id: posting.id,
      public_site_id,
      tenant_id: params.tenant_id,
    }))
    const { error: linkErr } = await db.from('job_posting_public_sites').insert(rows)
    if (linkErr) throw linkErr
  }

  return posting
}

export async function updateJobPosting(
  id: string,
  patch: Partial<Pick<JobPosting, 'title' | 'description' | 'status' | 'public_slug' | 'site_id' | 'department_id' | 'job_position_id' | 'interviewer_guide'>>,
): Promise<JobPosting> {
  const { data, error } = await db
    .from('job_postings')
    .update({ ...patch, updated_at: new Date().toISOString() })
    .eq('id', id)
    .select('*')
    .single()
  if (error) throw error
  return data as JobPosting
}

export async function setPostingPublicSites(
  tenantId: string,
  jobPostingId: string,
  publicSiteIds: string[],
): Promise<void> {
  const current = await listPostingPublicSites(jobPostingId)
  const desired = [...new Set(publicSiteIds)]
  const toAdd = desired.filter((id) => !current.includes(id))
  const toRemove = current.filter((id) => !desired.includes(id))

  // Insert first so published postings never briefly hit 0 public sites
  if (toAdd.length > 0) {
    const { error } = await db.from('job_posting_public_sites').insert(
      toAdd.map((public_site_id) => ({
        job_posting_id: jobPostingId,
        public_site_id,
        tenant_id: tenantId,
      })),
    )
    if (error) throw error
  }

  for (const publicSiteId of toRemove) {
    const { error } = await db
      .from('job_posting_public_sites')
      .delete()
      .eq('job_posting_id', jobPostingId)
      .eq('public_site_id', publicSiteId)
    if (error) throw error
  }
}


export async function listApplicationsForPosting(
  jobPostingId: string,
): Promise<JobPostingApplicationRow[]> {
  const { data, error } = await db
    .from('applications')
    .select(
      'id, created_at, source, candidate_visible_status, outcome_communicated_at, outcome_kind, hired_employee_id, hired_at, purge_at, stage_id, job_posting_id, cv_storage_path, retention_preference, retention_months, cv_structured, cv_structured_at, applicant:applicants(full_name, email, phone, email_verified_at)',
    )
    .eq('job_posting_id', jobPostingId)
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as JobPostingApplicationRow[]
}

export async function listApplicationsForTenant(
  filters: TenantApplicationsFilters = {},
): Promise<JobPostingApplicationRow[]> {
  let query = db
    .from('applications')
    .select(
      'id, created_at, source, candidate_visible_status, outcome_communicated_at, outcome_kind, hired_employee_id, hired_at, purge_at, stage_id, job_posting_id, cv_storage_path, retention_preference, retention_months, cv_structured, cv_structured_at, applicant:applicants(full_name, email, phone, email_verified_at), job_posting:job_postings(id, title, status, job_position_id)',
    )
    .order('created_at', { ascending: false })

  if (filters.postingId) {
    query = query.eq('job_posting_id', filters.postingId)
  }

  const { data, error } = await query
  if (error) throw error

  let rows = (data ?? []) as JobPostingApplicationRow[]

  if (filters.jobPositionId) {
    rows = rows.filter((r) => r.job_posting?.job_position_id === filters.jobPositionId)
  }

  if (filters.postingStatus && filters.postingStatus !== 'all') {
    if (filters.postingStatus === 'live') {
      rows = rows.filter((r) => r.job_posting?.status === 'published')
    } else {
      rows = rows.filter((r) => r.job_posting?.status === filters.postingStatus)
    }
  }

  const search = filters.search?.trim().toLowerCase()
  if (search) {
    rows = rows.filter((r) => {
      const name = r.applicant?.full_name?.toLowerCase() ?? ''
      const email = r.applicant?.email?.toLowerCase() ?? ''
      const title = r.job_posting?.title?.toLowerCase() ?? ''
      return name.includes(search) || email.includes(search) || title.includes(search)
    })
  }

  return rows
}

export async function listAllPipelineStages(tenantId: string): Promise<PipelineStage[]> {
  const { data, error } = await db
    .from('pipeline_stages')
    .select('*')
    .eq('tenant_id', tenantId)
    .order('position', { ascending: true })
  if (error) throw error
  return (data ?? []) as PipelineStage[]
}

/** Map an application stage_id onto a tenant-default column id (by name when override). */
export function resolveTenantColumnId(
  stageId: string | null,
  tenantStages: PipelineStage[],
  allStagesById: Map<string, PipelineStage>,
): string | null {
  if (!stageId) return null
  const stage = allStagesById.get(stageId)
  if (!stage) return null
  if (!stage.job_posting_id) return stage.id
  const byName = tenantStages.find((s) => s.name === stage.name)
  if (byName) return byName.id
  const byPos = tenantStages.find((s) => s.position === stage.position)
  return byPos?.id ?? null
}

export function resolveTargetStageForPosting(
  tenantStage: PipelineStage,
  postingStages: PipelineStage[],
): PipelineStage | null {
  return (
    postingStages.find((s) => s.name === tenantStage.name) ??
    postingStages.find((s) => s.position === tenantStage.position) ??
    null
  )
}

export async function listPipelineStagesForPosting(
  tenantId: string,
  jobPostingId: string,
): Promise<PipelineStage[]> {
  const { data: override, error: ovErr } = await db
    .from('pipeline_stages')
    .select('*')
    .eq('tenant_id', tenantId)
    .eq('job_posting_id', jobPostingId)
    .order('position', { ascending: true })
  if (ovErr) throw ovErr
  if ((override ?? []).length > 0) return override as PipelineStage[]

  return listTenantDefaultPipelineStages(tenantId)
}

export async function listTenantDefaultPipelineStages(tenantId: string): Promise<PipelineStage[]> {
  const { data, error } = await db
    .from('pipeline_stages')
    .select('*')
    .eq('tenant_id', tenantId)
    .is('job_posting_id', null)
    .order('position', { ascending: true })
  if (error) throw error
  return (data ?? []) as PipelineStage[]
}

export async function listPostingOverridePipelineStages(
  tenantId: string,
  jobPostingId: string,
): Promise<PipelineStage[]> {
  const { data, error } = await db
    .from('pipeline_stages')
    .select('*')
    .eq('tenant_id', tenantId)
    .eq('job_posting_id', jobPostingId)
    .order('position', { ascending: true })
  if (error) throw error
  return (data ?? []) as PipelineStage[]
}

export async function createPipelineStage(input: {
  tenantId: string
  jobPostingId?: string | null
  name: string
  position: number
  isTerminalHire?: boolean
  isTerminalReject?: boolean
}): Promise<PipelineStage> {
  const { data, error } = await db
    .from('pipeline_stages')
    .insert({
      tenant_id: input.tenantId,
      job_posting_id: input.jobPostingId ?? null,
      name: input.name.trim(),
      position: input.position,
      is_terminal_hire: input.isTerminalHire ?? false,
      is_terminal_reject: input.isTerminalReject ?? false,
    })
    .select('*')
    .single()
  if (error) throw error
  return data as PipelineStage
}

export async function updatePipelineStage(
  id: string,
  patch: Partial<Pick<PipelineStage, 'name' | 'position' | 'is_terminal_hire' | 'is_terminal_reject'>>,
): Promise<void> {
  const { error } = await db.from('pipeline_stages').update(patch).eq('id', id)
  if (error) throw error
}

export async function deletePipelineStage(id: string): Promise<void> {
  const { error } = await db.from('pipeline_stages').delete().eq('id', id)
  if (error) throw error
}

export async function clonePipelineStagesToPosting(jobPostingId: string): Promise<{ cloned: number }> {
  const { data, error } = await db.rpc('clone_pipeline_stages_to_posting', {
    p_job_posting_id: jobPostingId,
  })
  if (error) throw error
  return data as { cloned: number }
}

export async function deletePipelineStageOverride(
  jobPostingId: string,
): Promise<{ deleted: number }> {
  const { data, error } = await db.rpc('delete_pipeline_stage_override', {
    p_job_posting_id: jobPostingId,
  })
  if (error) throw error
  return data as { deleted: number }
}

export async function moveApplicationStage(
  applicationId: string,
  stageId: string,
): Promise<{ application_id: string; stage_id: string; candidate_visible_status: string }> {
  const { data, error } = await db.rpc('move_application_stage', {
    p_application_id: applicationId,
    p_stage_id: stageId,
  })
  if (error) throw error
  return data as { application_id: string; stage_id: string; candidate_visible_status: string }
}

export type CommunicateOutcomeResult = {
  application_id: string
  already_communicated: boolean
  outcome_kind?: string
  candidate_visible_status: string
  email_locale?: string
}

export async function communicateApplicationOutcome(
  applicationId: string,
  outcomeKind: 'rejected' | 'withdrawn' = 'rejected',
  prefsBaseUrl?: string | null,
): Promise<CommunicateOutcomeResult> {
  const { data, error } = await db.rpc('communicate_application_outcome', {
    p_application_id: applicationId,
    p_outcome_kind: outcomeKind,
    p_prefs_base_url: prefsBaseUrl ?? null,
  })
  if (error) throw error
  return data as CommunicateOutcomeResult
}

export type HireApplicationResult = {
  application_id: string
  employee_id: string
  lifecycle_state: string
  already_hired: boolean
  email_locale?: string
}

export async function hireApplication(params: {
  applicationId: string
  siteId?: string | null
  departmentId?: string | null
  startsOn?: string | null
  jobPositionId?: string | null
}): Promise<HireApplicationResult> {
  const { data, error } = await db.rpc('hire_application', {
    p_application_id: params.applicationId,
    p_site_id: params.siteId ?? null,
    p_department_id: params.departmentId ?? null,
    p_starts_on: params.startsOn ?? null,
    p_job_position_id: params.jobPositionId ?? null,
  })
  if (error) throw error
  return data as HireApplicationResult
}

export type ImportApplicationsBulkResult = {
  created: number
  skipped_duplicate: number
  art14_queued: number
  errors: Array<{ row: number; code: string; message: string }>
}

export async function importApplicationsBulk(params: {
  jobPostingId: string
  rows: Array<{
    full_name: string
    email: string
    phone?: string | null
    locale?: string | null
    cover_message?: string | null
  }>
  importSourceLabel?: string | null
}): Promise<ImportApplicationsBulkResult> {
  const { data, error } = await db.rpc('import_applications_bulk', {
    p_job_posting_id: params.jobPostingId,
    p_rows: params.rows,
    p_import_source_label: params.importSourceLabel ?? null,
  })
  if (error) throw error
  return data as ImportApplicationsBulkResult
}

export type ExportApplicationsResult = {
  signed_url: string
  filename: string
  row_count: number
  excluded_count: number
  expires_in: number
}

/** Server-side export via Edge: signed URL only (no csv_text in browser). */
export async function exportJobPostingApplicationsCsv(
  jobPostingId: string,
  ackWarning: boolean,
  tenantId: string,
): Promise<ExportApplicationsResult> {
  const { data, error } = await supabase.functions.invoke(
    'export-recruitment-applications',
    {
      headers: { 'x-tenant-id': tenantId },
      body: {
        job_posting_id: jobPostingId,
        ack_warning: ackWarning,
      },
    },
  )
  if (error) throw error
  const payload = data as ExportApplicationsResult & {
    error?: { code?: string; message?: string }
  }
  if (payload?.error) {
    throw new Error(payload.error.message || payload.error.code || 'export_failed')
  }
  if (!payload?.signed_url) {
    throw new Error('signed_url_missing')
  }
  return payload
}

export async function createCvSignedUrl(cvStoragePath: string, expiresIn = 900): Promise<string> {
  const { data, error } = await supabase.storage
    .from('recruitment-cvs')
    .createSignedUrl(cvStoragePath, expiresIn)
  if (error) throw error
  if (!data?.signedUrl) throw new Error('signed_url_missing')
  return data.signedUrl
}

export function buildPublicApplyUrl(
  originOrBase: string,
  publicSiteSlug: string,
  postingSlug: string,
  src: 'web' | 'qr' | 'whatsapp' = 'web',
  locale = 'ca',
): string {
  const base = originOrBase.replace(/\/$/, '')
  const path = `/${publicSiteSlug}/${locale}/careers/${postingSlug}`
  const q = src === 'web' ? '' : `?src=${src}`
  return `${base}${path}${q}`
}

export function buildWhatsAppShareUrl(applyUrl: string, jobTitle: string): string {
  const text = `Oferta: ${jobTitle}\n${applyUrl}`
  return `https://wa.me/?text=${encodeURIComponent(text)}`
}

export type InterviewType = 'phone' | 'online' | 'onsite'
export type InterviewStatus = 'scheduled' | 'completed' | 'cancelled' | 'no_show'

export type Interview = {
  id: string
  tenant_id: string
  application_id: string
  job_posting_id: string
  type: InterviewType
  scheduled_at: string | null
  duration_minutes: number | null
  location_or_link: string | null
  notes: string | null
  status: InterviewStatus
  created_by: string | null
  created_at: string
  updated_at: string
}

export async function listInterviewsForApplication(
  applicationId: string,
): Promise<Interview[]> {
  const { data, error } = await db
    .from('interviews')
    .select('*')
    .eq('application_id', applicationId)
    .order('scheduled_at', { ascending: true, nullsFirst: false })
  if (error) throw error
  return (data ?? []) as Interview[]
}

export type UpsertInterviewParams = {
  id?: string
  tenant_id: string
  application_id: string
  type: InterviewType
  scheduled_at?: string | null
  duration_minutes?: number | null
  location_or_link?: string | null
  notes?: string | null
  status?: InterviewStatus
}

export async function createInterview(params: UpsertInterviewParams): Promise<Interview> {
  const { data, error } = await db
    .from('interviews')
    .insert({
      tenant_id: params.tenant_id,
      application_id: params.application_id,
      type: params.type,
      scheduled_at: params.scheduled_at ?? null,
      duration_minutes: params.duration_minutes ?? 60,
      location_or_link: params.location_or_link ?? null,
      notes: params.notes ?? null,
      status: params.status ?? 'scheduled',
    })
    .select('*')
    .single()
  if (error) throw error
  return data as Interview
}

export async function updateInterview(
  id: string,
  patch: Partial<
    Pick<
      Interview,
      'type' | 'scheduled_at' | 'duration_minutes' | 'location_or_link' | 'notes' | 'status'
    >
  >,
): Promise<Interview> {
  const { data, error } = await db
    .from('interviews')
    .update({ ...patch, updated_at: new Date().toISOString() })
    .eq('id', id)
    .select('*')
    .single()
  if (error) throw error
  return data as Interview
}

export async function deleteInterview(id: string): Promise<void> {
  const { error } = await db.from('interviews').delete().eq('id', id)
  if (error) throw error
}

export type RightsRequestType =
  | 'access'
  | 'erasure'
  | 'rectification'
  | 'restriction'
  | 'portability'
  | 'objection'
export type RightsRequestStatus = 'pending_review' | 'fulfilled' | 'rejected'
export type RightsSlaBadge = 'ok' | 'due_soon' | 'overdue'

export type ApplicantDataRequestRow = {
  id: string
  applicant_id: string | null
  request_type: RightsRequestType
  status: RightsRequestStatus
  fulfilled_via: string | null
  requester_email_masked: string
  message: string | null
  rejection_reason: string | null
  resolution_notes: string | null
  due_at: string
  sla_reminded_at: string | null
  resolved_at: string | null
  resolved_by: string | null
  export_storage_path: string | null
  created_at: string
  sla_badge: RightsSlaBadge
  applicant_full_name?: string | null
  applicant_phone?: string | null
  processing_restricted_at?: string | null
  objection_at?: string | null
}

export async function listApplicantDataRequests(
  status?: RightsRequestStatus | null,
): Promise<ApplicantDataRequestRow[]> {
  const { data, error } = await db.rpc('list_applicant_data_requests', {
    p_status: status ?? null,
  })
  if (error) throw error
  const items = (data as { items?: ApplicantDataRequestRow[] } | null)?.items
  return items ?? []
}

export async function resolveApplicantDataRequest(
  id: string,
  action: 'approve' | 'reject',
  rejectionReason?: string | null,
  exportBaseUrl?: string | null,
  resolutionNotes?: string | null,
  rectifyFullName?: string | null,
  rectifyPhone?: string | null,
): Promise<{ id: string; status: string; fulfilled_via?: string }> {
  const { data, error } = await db.rpc('resolve_applicant_data_request', {
    p_id: id,
    p_action: action,
    p_rejection_reason: rejectionReason ?? null,
    p_export_base_url: exportBaseUrl ?? null,
    p_resolution_notes: resolutionNotes ?? null,
    p_rectify_full_name: rectifyFullName ?? null,
    p_rectify_phone: rectifyPhone ?? null,
  })
  if (error) throw error
  return data as { id: string; status: string; fulfilled_via?: string }
}

export async function revealApplicantDataRequestEmail(
  id: string,
): Promise<{ id: string; requester_email: string; requester_email_masked: string }> {
  const { data, error } = await db.rpc('reveal_applicant_data_request_email', {
    p_id: id,
  })
  if (error) throw error
  return data as { id: string; requester_email: string; requester_email_masked: string }
}

export type AnalyticsMetric = {
  value: number | null
  suppressed: boolean
  n?: number
}

export type AnalyticsFunnelStep = {
  key: string
  count: number | null
  suppressed: boolean
}

export type AnalyticsBreakdownRow = {
  key: string
  label?: string
  count: number
}

export type AnalyticsMonthRow = {
  key: string
  applications: number | null
  applications_suppressed: boolean
  hires: number | null
  hires_suppressed: boolean
}

export type RecruitmentAnalytics = {
  min_cohort: number
  filters: {
    from: string | null
    to: string | null
    site_id: string | null
    job_posting_id: string | null
    department_id: string | null
  }
  kpis: {
    applications: AnalyticsMetric
    active_postings: AnalyticsMetric
    hires: AnalyticsMetric
    conversion_pct: AnalyticsMetric
    avg_days_to_first_interview: AnalyticsMetric
    avg_days_to_hire: AnalyticsMetric
  }
  funnel: AnalyticsFunnelStep[]
  by_source: AnalyticsBreakdownRow[]
  by_import_source_label: AnalyticsBreakdownRow[]
  by_month: AnalyticsMonthRow[]
  by_site: Array<AnalyticsBreakdownRow & { label: string }>
  by_posting: Array<AnalyticsBreakdownRow & { label: string }>
}

export type RecruitmentAnalyticsFilters = {
  from?: string | null
  to?: string | null
  siteId?: string | null
  jobPostingId?: string | null
  departmentId?: string | null
}

export async function getRecruitmentAnalytics(
  filters: RecruitmentAnalyticsFilters = {},
): Promise<RecruitmentAnalytics> {
  const { data, error } = await db.rpc('get_recruitment_analytics', {
    p_from: filters.from ?? null,
    p_to: filters.to ?? null,
    p_site_id: filters.siteId ?? null,
    p_job_posting_id: filters.jobPostingId ?? null,
    p_department_id: filters.departmentId ?? null,
  })
  if (error) throw error
  return data as RecruitmentAnalytics
}

export type InboundInboxStatus = 'unassigned' | 'assigned' | 'discarded'

export type InboundInboxItem = {
  id: string
  status: InboundInboxStatus
  from_email: string
  from_name: string | null
  subject: string | null
  body_text: string | null
  received_at: string
  detected_posting_id: string | null
  assigned_application_id: string | null
  assigned_posting_id: string | null
  assigned_at: string | null
  discarded_at: string | null
  discard_reason: string | null
  attachment_paths: string[]
  created_at: string
}

export async function listRecruitmentEmailInbox(
  status: InboundInboxStatus | null = 'unassigned',
): Promise<InboundInboxItem[]> {
  const { data, error } = await db.rpc('list_recruitment_email_inbox', {
    p_status: status,
  })
  if (error) throw error
  return (data ?? []) as InboundInboxItem[]
}

export async function assignRecruitmentInboxItem(
  id: string,
  jobPostingId: string,
): Promise<{ inbox_id: string; application?: { application_id: string }; posting_id: string }> {
  const { data, error } = await db.rpc('assign_recruitment_inbox_item', {
    p_id: id,
    p_job_posting_id: jobPostingId,
  })
  if (error) throw error
  return data as {
    inbox_id: string
    application?: { application_id: string }
    posting_id: string
  }
}

export async function discardRecruitmentInboxItem(
  id: string,
  reason?: string | null,
): Promise<{ inbox_id: string }> {
  const { data, error } = await db.rpc('discard_recruitment_inbox_item', {
    p_id: id,
    p_reason: reason ?? null,
  })
  if (error) throw error
  return data as { inbox_id: string }
}

// ---------------------------------------------------------------------------
// REC-8 — AI assist
// ---------------------------------------------------------------------------

export async function acceptRecruitmentAiChecklist(
  tenantId: string,
  acceptDpa: boolean,
  acceptTransfer: boolean,
): Promise<{ ok: boolean }> {
  const { data, error } = await db.rpc('accept_recruitment_ai_checklist', {
    p_tenant_id: tenantId,
    p_accept_dpa: acceptDpa,
    p_accept_transfer: acceptTransfer,
  })
  if (error) throw error
  return data as { ok: boolean }
}

export async function setRecruitmentAiAssistEnabled(
  tenantId: string,
  enabled: boolean,
): Promise<{ ok: boolean; ai_assist_enabled: boolean }> {
  const { data, error } = await db.rpc('set_recruitment_ai_assist_enabled', {
    p_tenant_id: tenantId,
    p_enabled: enabled,
  })
  if (error) throw error
  return data as { ok: boolean; ai_assist_enabled: boolean }
}

export async function saveApplicationCvStructured(
  applicationId: string,
  payload: CvStructuredPayload,
): Promise<{ ok: boolean; cv_structured: CvStructuredPayload }> {
  const { data, error } = await db.rpc('save_application_cv_structured', {
    p_application_id: applicationId,
    p_payload: payload,
  })
  if (error) throw error
  return data as { ok: boolean; cv_structured: CvStructuredPayload }
}

export type StructureCvResult =
  | {
      status: 'proposal'
      application_id: string
      proposal: CvStructuredPayload
      provider?: string
      model?: string
      chars_sent?: number
      warnings?: unknown
    }
  | {
      status: 'needs_human_review'
      reason: string
      application_id: string
      chars_extracted?: number
    }

export async function structureRecruitmentCv(
  tenantId: string,
  applicationId: string,
): Promise<StructureCvResult> {
  const { data, error } = await supabase.functions.invoke('structure-recruitment-cv', {
    headers: { 'x-tenant-id': tenantId },
    body: { application_id: applicationId },
  })
  if (error) {
    const detailed = await getFunctionErrorMessage(error)
    throw new Error(detailed ?? error.message)
  }
  const responseError = getResponseErrorMessage(data)
  if (responseError) throw new Error(responseError)
  return data as StructureCvResult
}
