'use server'

import { Prisma } from '@prisma/client'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type EmailStatus =
  | 'queued'
  | 'processing'
  | 'sent'
  | 'delivered'
  | 'bounced'
  | 'failed'
  | 'complained'
  | 'suppressed'

export interface EmailLogRow {
  id: string
  tenant_id: string
  tenant_name: string | null
  site_id: string | null
  site_name: string | null
  status: EmailStatus
  email_type: string
  from_email: string
  from_name: string | null
  to_emails: string[]
  subject: string | null
  provider_message_id: string | null
  attempt_count: number
  max_retries: number
  is_dead_letter: boolean
  last_error: string | null
  error_history: unknown
  metadata: unknown
  created_at: string
  sent_at: string | null
  delivered_at: string | null
  processing_time_ms: number | null
  delivery_time_ms: number | null
}

export interface EmailLogDetail extends EmailLogRow {
  cc_emails: string[] | null
  bcc_emails: string[] | null
  reply_to: string | null
  html_body: string | null
  text_body: string | null
  tags: unknown
  locked_by: string | null
}

export interface GetEmailLogsParams {
  page?: number
  pageSize?: number
  dateFrom?: string
  dateTo?: string
  tenantId?: string
  siteId?: string
  status?: string
  search?: string
  sortColumn?: string
  sortAsc?: boolean
}

export interface EmailLogsResult {
  rows: EmailLogRow[]
  total: number
  page: number
  pageSize: number
}

export interface TenantOption {
  id: string
  name: string
}

export interface SiteOption {
  id: string
  name: string
}

// ---------------------------------------------------------------------------
// Auth guard
// ---------------------------------------------------------------------------

async function assertBackoffice() {
  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()
  if (error || !user) throw new Error('Unauthenticated')
  const role = user.app_metadata?.role as string | undefined
  if (role !== 'admin' && role !== 'support') throw new Error('Forbidden')
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function toISOOrNull(val: unknown): string | null {
  if (val == null) return null
  if (val instanceof Date) return val.toISOString()
  return String(val)
}

function normalizeRow(r: EmailLogRow): EmailLogRow {
  return {
    ...r,
    to_emails: Array.isArray(r.to_emails) ? r.to_emails : [],
    created_at: toISOOrNull(r.created_at) ?? '',
    sent_at: toISOOrNull(r.sent_at),
    delivered_at: toISOOrNull(r.delivered_at),
    processing_time_ms: r.processing_time_ms != null ? Number(r.processing_time_ms) : null,
    delivery_time_ms: r.delivery_time_ms != null ? Number(r.delivery_time_ms) : null,
  }
}

// ---------------------------------------------------------------------------
// getEmailLogs — paginated list with filters
// ---------------------------------------------------------------------------

export async function getEmailLogs(
  params: GetEmailLogsParams = {},
): Promise<EmailLogsResult> {
  await assertBackoffice()

  const page = Math.max(1, params.page ?? 1)
  const pageSize = Math.min(100, Math.max(10, params.pageSize ?? 50))
  const offset = (page - 1) * pageSize

  const now = new Date()
  const defaultFrom = new Date(now)
  defaultFrom.setDate(defaultFrom.getDate() - 7)

  const dateFrom = params.dateFrom ? new Date(params.dateFrom) : defaultFrom
  const dateTo = params.dateTo ? new Date(params.dateTo + 'T23:59:59.999Z') : now

  const tenantFilter: string | null = params.tenantId || null
  const siteFilter: string | null = params.siteId || null
  const statusFilter: string | null = params.status || null
  const searchLike: string | null = params.search?.trim()
    ? `%${params.search.trim()}%`
    : null

  const SORTABLE_COLUMNS: Record<string, string> = {
    created_at: 'el.created_at',
    status: 'el.status::text',
    from_email: 'el.from_email',
    attempt_count: 'el.attempt_count',
    processing_time_ms: '(EXTRACT(EPOCH FROM (el.sent_at - el.created_at)) * 1000.0)',
  }
  const sortColExpr = SORTABLE_COLUMNS[params.sortColumn ?? 'created_at'] ?? 'el.created_at'
  const sortDirection = params.sortAsc ? Prisma.raw('ASC') : Prisma.raw('DESC')

  const rows = await prisma.$queryRaw<EmailLogRow[]>(Prisma.sql`
    SELECT
      el.id,
      el.tenant_id,
      t.name AS tenant_name,
      el.site_id,
      s.name AS site_name,
      el.status::text AS status,
      el.email_type::text AS email_type,
      el.from_email,
      el.from_name,
      el.to_emails,
      el.subject,
      el.provider_message_id,
      el.attempt_count,
      el.max_retries,
      el.is_dead_letter,
      el.last_error,
      el.error_history,
      el.metadata,
      el.created_at,
      el.sent_at,
      el.delivered_at,
      EXTRACT(EPOCH FROM (el.sent_at - el.created_at)) * 1000.0 AS processing_time_ms,
      EXTRACT(EPOCH FROM (el.delivered_at - el.sent_at)) * 1000.0 AS delivery_time_ms
    FROM data.email_logs el
    LEFT JOIN data.tenants t ON t.id = el.tenant_id
    LEFT JOIN data.sites s ON s.id = el.site_id
    WHERE el.created_at >= ${dateFrom}
      AND el.created_at <= ${dateTo}
      AND (${tenantFilter}::text IS NULL OR el.tenant_id::text = ${tenantFilter})
      AND (${siteFilter}::text IS NULL OR el.site_id::text = ${siteFilter})
      AND (${statusFilter}::text IS NULL OR el.status::text = ${statusFilter})
      AND (
        ${searchLike}::text IS NULL
        OR EXISTS (SELECT 1 FROM unnest(el.to_emails) AS e WHERE e ILIKE ${searchLike})
        OR el.subject ILIKE ${searchLike}
        OR el.provider_message_id ILIKE ${searchLike}
      )
    ORDER BY ${Prisma.raw(sortColExpr)} ${sortDirection}
    LIMIT ${pageSize} OFFSET ${offset}
  `)

  const countResult = await prisma.$queryRaw<[{ count: number }]>`
    SELECT COUNT(*)::int AS count
    FROM data.email_logs el
    WHERE el.created_at >= ${dateFrom}
      AND el.created_at <= ${dateTo}
      AND (${tenantFilter}::text IS NULL OR el.tenant_id::text = ${tenantFilter})
      AND (${siteFilter}::text IS NULL OR el.site_id::text = ${siteFilter})
      AND (${statusFilter}::text IS NULL OR el.status::text = ${statusFilter})
      AND (
        ${searchLike}::text IS NULL
        OR EXISTS (SELECT 1 FROM unnest(el.to_emails) AS e WHERE e ILIKE ${searchLike})
        OR el.subject ILIKE ${searchLike}
        OR el.provider_message_id ILIKE ${searchLike}
      )
  `

  return {
    rows: rows.map(normalizeRow),
    total: countResult[0]?.count ?? 0,
    page,
    pageSize,
  }
}

// ---------------------------------------------------------------------------
// getEmailLogDetail — full single log
// ---------------------------------------------------------------------------

export async function getEmailLogDetail(
  id: string,
): Promise<EmailLogDetail | null> {
  await assertBackoffice()

  const rows = await prisma.$queryRaw<EmailLogDetail[]>`
    SELECT
      el.id,
      el.tenant_id,
      t.name AS tenant_name,
      el.site_id,
      s.name AS site_name,
      el.status::text AS status,
      el.email_type::text AS email_type,
      el.from_email,
      el.from_name,
      el.to_emails,
      el.cc_emails,
      el.bcc_emails,
      el.reply_to,
      el.subject,
      el.html_body,
      el.text_body,
      el.provider_message_id,
      el.attempt_count,
      el.max_retries,
      el.is_dead_letter,
      el.last_error,
      el.error_history,
      el.metadata,
      el.tags,
      el.locked_by,
      el.created_at,
      el.sent_at,
      el.delivered_at,
      EXTRACT(EPOCH FROM (el.sent_at - el.created_at)) * 1000.0 AS processing_time_ms,
      EXTRACT(EPOCH FROM (el.delivered_at - el.sent_at)) * 1000.0 AS delivery_time_ms
    FROM data.email_logs el
    LEFT JOIN data.tenants t ON t.id = el.tenant_id
    LEFT JOIN data.sites s ON s.id = el.site_id
    WHERE el.id = ${id}::uuid
    LIMIT 1
  `

  const r = rows[0]
  if (!r) return null

  return {
    ...r,
    to_emails: Array.isArray(r.to_emails) ? r.to_emails : [],
    cc_emails: Array.isArray(r.cc_emails) ? r.cc_emails : null,
    bcc_emails: Array.isArray(r.bcc_emails) ? r.bcc_emails : null,
    created_at: toISOOrNull(r.created_at) ?? '',
    sent_at: toISOOrNull(r.sent_at),
    delivered_at: toISOOrNull(r.delivered_at),
    processing_time_ms: r.processing_time_ms != null ? Number(r.processing_time_ms) : null,
    delivery_time_ms: r.delivery_time_ms != null ? Number(r.delivery_time_ms) : null,
  }
}

// ---------------------------------------------------------------------------
// getTenantOptions — for filter dropdown
// ---------------------------------------------------------------------------

export async function getTenantOptions(): Promise<TenantOption[]> {
  await assertBackoffice()
  return prisma.$queryRaw<TenantOption[]>`
    SELECT id::text, name
    FROM data.tenants
    WHERE is_active = true
    ORDER BY name
  `
}

// ---------------------------------------------------------------------------
// getSiteOptions — for site filter dropdown (scoped to a tenant)
// ---------------------------------------------------------------------------

export async function getSiteOptions(tenantId: string): Promise<SiteOption[]> {
  await assertBackoffice()
  if (!tenantId) return []
  return prisma.$queryRaw<SiteOption[]>`
    SELECT id::text, name
    FROM data.sites
    WHERE tenant_id = ${tenantId}::uuid
      AND is_active = true
    ORDER BY name
  `
}

// ---------------------------------------------------------------------------
// syncResendStatus — calls Resend API directly and updates the log metadata
// ---------------------------------------------------------------------------

export interface ResendSyncResult {
  resend_data: Record<string, unknown>
  previous_status: string
  next_status: string
  updated_at: string
}

function mapResendEventToStatus(
  lastEvent: unknown,
  currentStatus: EmailStatus,
  resendData: Record<string, unknown>,
): { nextStatus: EmailStatus; deliveredAt: Date | null | undefined } {
  if (lastEvent === 'delivered') {
    // Prefer the real delivery timestamp from Resend over the sync wall-clock time.
    // Resend may expose it as `last_event_data.created_at`, `delivered_at`, or similar.
    const rawTs =
      (resendData.last_event_data as Record<string, unknown> | null | undefined)
        ?.created_at ??
      resendData.delivered_at ??
      null
    const deliveredAt =
      typeof rawTs === 'string' && rawTs ? new Date(rawTs) : null
    return { nextStatus: 'delivered', deliveredAt }
  }
  if (lastEvent === 'bounced') {
    return { nextStatus: 'bounced', deliveredAt: undefined }
  }
  if (lastEvent === 'complained') {
    return { nextStatus: 'complained', deliveredAt: undefined }
  }
  if (lastEvent === 'suppressed') {
    return { nextStatus: 'suppressed', deliveredAt: undefined }
  }
  if (lastEvent === 'delivery_delayed') {
    return { nextStatus: 'processing', deliveredAt: undefined }
  }

  return { nextStatus: currentStatus, deliveredAt: undefined }
}

export async function syncResendStatus(
  emailLogId: string,
): Promise<ResendSyncResult> {
  await assertBackoffice()

  const resendApiKey = process.env.RESEND_API_KEY
  if (!resendApiKey) {
    throw new Error('RESEND_API_KEY no configurada al servidor')
  }

  // 1. Fetch log from DB
  const rows = await prisma.$queryRaw<
    { id: string; status: string; provider_message_id: string | null; metadata: unknown }[]
  >`
    SELECT id, status::text, provider_message_id, metadata
    FROM data.email_logs
    WHERE id = ${emailLogId}::uuid
    LIMIT 1
  `
  const log = rows[0]
  if (!log) throw new Error('Registre no trobat')
  if (!log.provider_message_id) {
    throw new Error(
      'Aquest registre no té provider_message_id — no es pot sincronitzar amb Resend',
    )
  }

  // 2. Call Resend API
  const resendRes = await fetch(
    `https://api.resend.com/emails/${log.provider_message_id}`,
    {
      headers: {
        Authorization: `Bearer ${resendApiKey}`,
        'Content-Type': 'application/json',
      },
    },
  )

  const resendData = (await resendRes.json()) as Record<string, unknown>

  if (!resendRes.ok) {
    throw new Error(
      `Resend API error ${resendRes.status}: ${resendData?.message ?? resendRes.statusText}`,
    )
  }

  // 3. Map Resend event to internal state and persist changes
  const now = new Date().toISOString()
  const currentStatus = log.status as EmailStatus
  const { nextStatus: rawNextStatus, deliveredAt } = mapResendEventToStatus(
    resendData.last_event,
    currentStatus,
    resendData,
  )

  // Safety guard: if current status is terminal and the mapped next status differs,
  // keep the current status to avoid trigger violations. Only metadata gets updated.
  const BACKEND_TERMINAL: ReadonlySet<string> = new Set([
    'delivered', 'bounced', 'failed', 'complained', 'suppressed',
  ])
  const nextStatus: EmailStatus =
    BACKEND_TERMINAL.has(currentStatus) && rawNextStatus !== currentStatus
      ? currentStatus
      : rawNextStatus
  const existingMetadata =
    (log.metadata as Record<string, unknown> | null) ?? {}

  const updatedMetadata = {
    ...existingMetadata,
    resend_sync: {
      synced_at: now,
      resend_response: resendData,
    },
  }

  await prisma.$executeRaw`
    UPDATE data.email_logs
    SET
      status = ${nextStatus}::data.email_status,
      delivered_at = CASE
        WHEN ${deliveredAt ?? null}::timestamptz IS NOT NULL
          THEN ${deliveredAt ?? null}::timestamptz
        WHEN ${nextStatus}::text = 'delivered' AND delivered_at IS NOT NULL
          THEN delivered_at
        WHEN ${nextStatus}::text <> 'delivered'
          THEN NULL
        ELSE delivered_at
      END,
      metadata = ${JSON.stringify(updatedMetadata)}::jsonb
    WHERE id = ${emailLogId}::uuid
  `

  return {
    resend_data: resendData,
    previous_status: log.status,
    next_status: nextStatus,
    updated_at: now,
  }
}

// ---------------------------------------------------------------------------
// logEmailBodyViewed — audit log when an admin views the body of an email
// ---------------------------------------------------------------------------

export async function logEmailBodyViewed(
  emailLogId: string,
  logDetail: Pick<EmailLogDetail, 'tenant_id' | 'subject' | 'sent_at' | 'to_emails'>,
): Promise<void> {
  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()
  if (error || !user) throw new Error('Unauthenticated')
  const role = user.app_metadata?.role as string | undefined
  if (role !== 'admin' && role !== 'support') throw new Error('Forbidden')

  try {
    await prisma.$executeRaw`
      INSERT INTO data.audit_logs (tenant_id, user_id, action, entity_type, entity_id, payload)
      VALUES (
        ${logDetail.tenant_id}::uuid,
        ${user.id}::uuid,
        'EMAIL_BODY_VIEWED',
        'email_log',
        ${emailLogId}::uuid,
        ${JSON.stringify({
          subject: logDetail.subject,
          sent_at: logDetail.sent_at,
          to_emails: logDetail.to_emails,
          portal: 'admin-portal',
          viewer_role: role,
        })}::jsonb
      )
    `
  } catch (auditErr) {
    // fire-and-forget — no trenquem el flux principal per un error d'auditoria
    console.warn('[audit] logEmailBodyViewed error:', auditErr)
  }
}

// ---------------------------------------------------------------------------
// exportEmailLogsCsv — returns a CSV string for client-side download
// ---------------------------------------------------------------------------

export async function exportEmailLogsCsv(
  params: GetEmailLogsParams,
): Promise<string> {
  await assertBackoffice()

  // Fetch up to 5000 rows (max 100 per page, up to 50 pages)
  const firstPage = await getEmailLogs({ ...params, page: 1, pageSize: 100 })
  let allRows = firstPage.rows

  if (firstPage.total > 100) {
    const maxRows = Math.min(firstPage.total, 5000)
    const totalPages = Math.ceil(maxRows / 100)
    const pagePromises = Array.from({ length: totalPages - 1 }, (_, i) =>
      getEmailLogs({ ...params, page: i + 2, pageSize: 100 }).then((r) => r.rows),
    )
    const extraPages = await Promise.all(pagePromises)
    allRows = [...allRows, ...extraPages.flat()]
  }

  const esc = (v: unknown): string => {
    const s = v == null ? '' : String(v)
    return `"${s.replace(/"/g, '""')}"`
  }

  const headers = [
    'ID',
    'Tenant',
    'Estat',
    'De',
    'Per a',
    'Assumpte',
    'Provider Message ID',
    'Intents',
    'Dead Letter',
    'Creat el',
    'Enviat el',
    'Entregat el',
  ]

  const csvRows = allRows.map((r) => [
    esc(r.id),
    esc(r.tenant_name ?? r.tenant_id),
    esc(r.status),
    esc(r.from_name ? `${r.from_name} <${r.from_email}>` : r.from_email),
    esc(r.to_emails.join('; ')),
    esc(r.subject),
    esc(r.provider_message_id),
    esc(r.attempt_count),
    esc(r.is_dead_letter ? 'Sí' : 'No'),
    esc(r.created_at),
    esc(r.sent_at),
    esc(r.delivered_at),
  ])

  return [headers.join(','), ...csvRows.map((row) => row.join(','))].join('\n')
}

// ---------------------------------------------------------------------------
// getEmailMetrics — aggregated data for Visual Insights Dashboard
// ---------------------------------------------------------------------------

export interface DailyVolumePoint {
  day: string
  queued: number
  processing: number
  sent: number
  delivered: number
  bounced: number
  failed: number
  avg_processing_ms: number | null
}

export interface StatusTotal {
  status: string
  count: number
}

export interface TopIssue {
  id: string
  label: string
  total: number
  errors: number
  error_rate: number
}

export interface EmailMetrics {
  daily_volume: DailyVolumePoint[]
  status_totals: StatusTotal[]
  top_issues: TopIssue[]
}

export type EmailMetricsParams = Pick<GetEmailLogsParams, 'dateFrom' | 'dateTo' | 'tenantId' | 'siteId'>

export async function getEmailMetrics(
  params: EmailMetricsParams = {},
): Promise<EmailMetrics> {
  await assertBackoffice()

  const now = new Date()
  const defaultFrom = new Date(now)
  defaultFrom.setDate(defaultFrom.getDate() - 7)

  const dateFrom = params.dateFrom ? new Date(params.dateFrom) : defaultFrom
  const dateTo = params.dateTo ? new Date(params.dateTo + 'T23:59:59.999Z') : now
  const tenantFilter: string | null = params.tenantId || null
  const siteFilter: string | null = params.siteId || null

  // When a specific tenant is selected, top issues = top sites within that tenant.
  // When global (no tenant), top issues = top tenants.
  const [dailyRows, statusRows, topRows, latencyRows] = await Promise.all([
    prisma.$queryRaw<Array<{ day: string; status: string; count: number }>>`
      SELECT
        to_char(date_trunc('day', created_at AT TIME ZONE 'UTC'), 'YYYY-MM-DD') AS day,
        status::text AS status,
        COUNT(*)::int AS count
      FROM data.email_logs
      WHERE created_at >= ${dateFrom}
        AND created_at <= ${dateTo}
        AND (${tenantFilter}::text IS NULL OR tenant_id::text = ${tenantFilter})
        AND (${siteFilter}::text IS NULL OR site_id::text = ${siteFilter})
      GROUP BY 1, 2
      ORDER BY 1
    `,
    prisma.$queryRaw<Array<{ status: string; count: number }>>`
      SELECT
        status::text AS status,
        COUNT(*)::int AS count
      FROM data.email_logs
      WHERE created_at >= ${dateFrom}
        AND created_at <= ${dateTo}
        AND (${tenantFilter}::text IS NULL OR tenant_id::text = ${tenantFilter})
        AND (${siteFilter}::text IS NULL OR site_id::text = ${siteFilter})
      GROUP BY 1
    `,
    tenantFilter
      ? prisma.$queryRaw<
          Array<{ id: string; label: string | null; total: number; errors: number }>
        >`
          SELECT
            el.site_id::text AS id,
            COALESCE(s.name, 'Global') AS label,
            COUNT(*)::int AS total,
            COUNT(*) FILTER (WHERE el.status::text IN ('bounced', 'failed'))::int AS errors
          FROM data.email_logs el
          LEFT JOIN data.sites s ON s.id = el.site_id
          WHERE el.created_at >= ${dateFrom}
            AND el.created_at <= ${dateTo}
            AND el.tenant_id::text = ${tenantFilter}
            AND (${siteFilter}::text IS NULL OR el.site_id::text = ${siteFilter})
          GROUP BY el.site_id, s.name
          ORDER BY errors DESC, total DESC
          LIMIT 5
        `
      : prisma.$queryRaw<
          Array<{ id: string; label: string | null; total: number; errors: number }>
        >`
          SELECT
            el.tenant_id::text AS id,
            t.name AS label,
            COUNT(*)::int AS total,
            COUNT(*) FILTER (WHERE el.status::text IN ('bounced', 'failed'))::int AS errors
          FROM data.email_logs el
          LEFT JOIN data.tenants t ON t.id = el.tenant_id
          WHERE el.created_at >= ${dateFrom}
            AND el.created_at <= ${dateTo}
          GROUP BY el.tenant_id, t.name
          ORDER BY errors DESC, total DESC
          LIMIT 5
        `,
    prisma.$queryRaw<Array<{ day: string; avg_processing_ms: number | null }>>`
      SELECT
        to_char(date_trunc('day', created_at AT TIME ZONE 'UTC'), 'YYYY-MM-DD') AS day,
        AVG(EXTRACT(EPOCH FROM (sent_at - created_at)) * 1000.0)
          FILTER (WHERE sent_at IS NOT NULL) AS avg_processing_ms
      FROM data.email_logs
      WHERE created_at >= ${dateFrom}
        AND created_at <= ${dateTo}
        AND (${tenantFilter}::text IS NULL OR tenant_id::text = ${tenantFilter})
        AND (${siteFilter}::text IS NULL OR site_id::text = ${siteFilter})
      GROUP BY 1
      ORDER BY 1
    `,
  ])

  // Pivot daily rows: (day, status, count) → { day, queued, processing, … }
  const pivotMap = new Map<string, DailyVolumePoint>()
  for (const row of dailyRows) {
    if (!pivotMap.has(row.day)) {
      pivotMap.set(row.day, {
        day: row.day,
        queued: 0,
        processing: 0,
        sent: 0,
        delivered: 0,
        bounced: 0,
        failed: 0,
        avg_processing_ms: null,
      })
    }
    const point = pivotMap.get(row.day)!
    const s = row.status as keyof Omit<DailyVolumePoint, 'day'>
    if (s in point) point[s] = Number(row.count)
  }

  for (const lr of latencyRows) {
    const point = pivotMap.get(lr.day)
    if (point) {
      point.avg_processing_ms = lr.avg_processing_ms != null ? Number(lr.avg_processing_ms) : null
    }
  }

  return {
    daily_volume: Array.from(pivotMap.values()),
    status_totals: statusRows.map((r) => ({ status: r.status, count: Number(r.count) })),
    top_issues: topRows.map((r) => ({
      id: r.id ?? 'unknown',
      label: r.label ?? r.id?.slice(0, 8) ?? '—',
      total: Number(r.total),
      errors: Number(r.errors),
      error_rate:
        Number(r.total) > 0 ? Math.round((Number(r.errors) / Number(r.total)) * 100) : 0,
    })),
  }
}
