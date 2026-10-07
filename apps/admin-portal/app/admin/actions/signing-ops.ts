'use server'

import { Prisma } from '@prisma/client'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

async function assertBackoffice() {
  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()
  if (error || !user) throw new Error('Unauthenticated')
  const role = user.app_metadata?.role as string | undefined
  if (role !== 'admin' && role !== 'support') throw new Error('Forbidden')
  return user
}

function toNumber(value: unknown): number {
  if (typeof value === 'number') return Number.isFinite(value) ? value : 0
  if (typeof value === 'bigint') return Number(value)
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}

function toIso(value: Date | string | null | undefined): string | null {
  if (!value) return null
  if (value instanceof Date) return value.toISOString()
  return new Date(value).toISOString()
}

export interface TenantOption {
  id: string
  name: string
}

export async function getSigningOpsTenantOptions(): Promise<TenantOption[]> {
  await assertBackoffice()
  return prisma.$queryRaw<TenantOption[]>`
    SELECT id::text AS id, name
    FROM data.tenants
    ORDER BY name ASC
  `
}

export interface SigningOpsLogRow {
  id: string
  tenant_id: string
  tenant_name: string | null
  integration_type: string
  operation_code: string
  status: string
  title: string
  error_code: string | null
  error_message: string | null
  entity_id: string | null
  correlation_id: string | null
  created_at: string
  resolved_at: string | null
}

export interface GetSigningOpsLogsParams {
  page?: number
  pageSize?: number
  dateFrom?: string
  dateTo?: string
  tenantId?: string
  status?: string
  operationCode?: string
  unresolvedOnly?: boolean
}

export interface SigningOpsLogsResult {
  rows: SigningOpsLogRow[]
  total: number
  page: number
  pageSize: number
}

export async function getSigningOpsLogs(
  params: GetSigningOpsLogsParams = {},
): Promise<SigningOpsLogsResult> {
  await assertBackoffice()

  const page = Math.max(1, params.page ?? 1)
  const pageSize = Math.min(100, Math.max(10, params.pageSize ?? 50))
  const offset = (page - 1) * pageSize
  const dateFrom = params.dateFrom
    ? new Date(`${params.dateFrom}T00:00:00.000Z`)
    : new Date(Date.now() - 7 * 24 * 60 * 60 * 1000)
  const dateTo = params.dateTo
    ? new Date(`${params.dateTo}T23:59:59.999Z`)
    : new Date()

  const filters: Prisma.Sql[] = [
    Prisma.sql`l.integration_type IN ('signing', 'pdf_generation')`,
    Prisma.sql`l.created_at >= ${dateFrom}`,
    Prisma.sql`l.created_at <= ${dateTo}`,
  ]
  if (params.tenantId) {
    filters.push(Prisma.sql`l.tenant_id = ${params.tenantId}::uuid`)
  }
  if (params.status) {
    filters.push(Prisma.sql`l.status = ${params.status}::data.operation_log_status`)
  }
  if (params.operationCode) {
    filters.push(Prisma.sql`l.operation_code ILIKE ${'%' + params.operationCode + '%'}`)
  }
  if (params.unresolvedOnly) {
    filters.push(Prisma.sql`l.resolved_at IS NULL`)
    filters.push(Prisma.sql`l.status IN ('failed', 'dead_letter', 'degraded')`)
  }

  const where = Prisma.sql`WHERE ${Prisma.join(filters, ' AND ')}`

  const [countRows, rows] = await Promise.all([
    prisma.$queryRaw<Array<{ total: bigint | number }>>`
      SELECT count(*)::int AS total
      FROM data.tenant_operation_logs l
      ${where}
    `,
    prisma.$queryRaw<
      Array<{
        id: string
        tenant_id: string
        tenant_name: string | null
        integration_type: string
        operation_code: string
        status: string
        title: string
        error_code: string | null
        error_message: string | null
        entity_id: string | null
        correlation_id: string | null
        created_at: Date
        resolved_at: Date | null
      }>
    >`
      SELECT
        l.id::text,
        l.tenant_id::text,
        t.name AS tenant_name,
        l.integration_type::text,
        l.operation_code,
        l.status::text,
        l.title,
        l.error_code,
        left(COALESCE(l.error_message, ''), 300) AS error_message,
        l.entity_id::text,
        l.correlation_id,
        l.created_at,
        l.resolved_at
      FROM data.tenant_operation_logs l
      LEFT JOIN data.tenants t ON t.id = l.tenant_id
      ${where}
      ORDER BY l.created_at DESC
      LIMIT ${pageSize} OFFSET ${offset}
    `,
  ])

  return {
    total: toNumber(countRows[0]?.total),
    page,
    pageSize,
    rows: rows.map((r) => ({
      ...r,
      created_at: toIso(r.created_at)!,
      resolved_at: toIso(r.resolved_at),
    })),
  }
}

export async function markSigningOpsLogResolved(
  logId: string,
  note?: string,
): Promise<{ ok: boolean; message?: string }> {
  await assertBackoffice()
  if (!logId) return { ok: false, message: 'missing id' }

  const updated = await prisma.$executeRaw`
    UPDATE data.tenant_operation_logs
    SET
      resolved_at = now(),
      resolution_note = NULLIF(trim(${note ?? 'platform_ops'}), ''),
      updated_at = now()
    WHERE id = ${logId}::uuid
      AND resolved_at IS NULL
  `
  return { ok: updated > 0, message: updated > 0 ? undefined : 'already resolved or not found' }
}

export interface QueueMetricCard {
  queue_name: string
  queue_length: number
  oldest_msg_age_sec: number
  archive_count: number
  available: boolean
  error_message?: string
}

async function safeQueueMetric(queueName: string): Promise<QueueMetricCard> {
  try {
    const [metricRows, archiveRows] = await Promise.all([
      prisma.$queryRaw<
        Array<{
          queue_length: number | bigint
          oldest_msg_age_sec: number | bigint
        }>
      >`
        SELECT queue_length, oldest_msg_age_sec
        FROM pgmq.metrics(${queueName});
      `,
      prisma.$queryRawUnsafe<Array<{ archive_count: number | bigint }>>(
        `SELECT count(*)::int AS archive_count FROM pgmq.a_${queueName.replace(/[^a-z0-9_]/gi, '')}`,
      ),
    ])
    return {
      queue_name: queueName,
      queue_length: toNumber(metricRows[0]?.queue_length),
      oldest_msg_age_sec: toNumber(metricRows[0]?.oldest_msg_age_sec),
      archive_count: toNumber(archiveRows[0]?.archive_count),
      available: true,
    }
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error)
    return {
      queue_name: queueName,
      queue_length: 0,
      oldest_msg_age_sec: 0,
      archive_count: 0,
      available: false,
      error_message: message.slice(0, 200),
    }
  }
}

export interface ReconcileHealth {
  backlog: number
  last_started_at: string | null
  last_finished_at: string | null
  last_ok: boolean | null
  last_error: string | null
  last_listed: number
  last_attempted: number
  last_attached: number
  last_skipped: number
  seconds_since_ok: number | null
}

export interface SigningOpsStats {
  submissions_7d: { native: number; docuseal: number }
  submissions_30d: { native: number; docuseal: number }
  outcomes_30d: Record<string, number>
  bridge_vs_generic_30d: { bridge: number; generic: number }
  low_credit_tenants: Array<{ tenant_id: string; tenant_name: string; credits: number }>
  platform_credits_total: number
  pdf_dead_letters: number
}

export interface SigningOpsAnomalies {
  top_failures_24h: Array<{
    tenant_id: string
    tenant_name: string | null
    failures: number
  }>
  top_failures_7d: Array<{
    tenant_id: string
    tenant_name: string | null
    failures: number
  }>
  stuck_submissions: number
  open_requests_no_delivery: number
  open_requests_artifact_failed: number
  webhook_spike_tenants: Array<{
    tenant_id: string
    tenant_name: string | null
    events_24h: number
    avg_7d: number
  }>
}

export interface SigningOpsDashboard {
  queues: QueueMetricCard[]
  reconcile: ReconcileHealth
  stats: SigningOpsStats
  anomalies: SigningOpsAnomalies
}

export async function getSigningOpsDashboard(): Promise<SigningOpsDashboard> {
  await assertBackoffice()

  const queues = await Promise.all([
    safeQueueMetric('document_pdf_queue'),
    safeQueueMetric('notification_dispatch_queue'),
    safeQueueMetric('reminders_queue'),
    safeQueueMetric('email_send_queue'),
  ])

  const [backlogRows, lastRunRows, lastOkRows] = await Promise.all([
    prisma.$queryRaw<Array<{ n: number | bigint }>>`
      SELECT count(*)::int AS n
      FROM data.signing_submissions ss
      WHERE ss.status = 'completed'
        AND ss.result_document_version_id IS NULL
        AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
        AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
        AND COALESCE(ss.metadata->>'artifact_status', 'failed') IN ('pending', 'failed')
        AND NULLIF(btrim(COALESCE(ss.artifact_retry_url, '')), '') IS NOT NULL
    `,
    prisma.$queryRaw<
      Array<{
        started_at: Date
        finished_at: Date | null
        ok: boolean
        error_text: string | null
        listed: number | null
        attempted: number | null
        attached: number | null
        skipped: number | null
      }>
    >`
      SELECT started_at, finished_at, ok, error_text, listed, attempted, attached, skipped
      FROM data.signing_ops_job_runs
      WHERE job_name = 'reconcile-docuseal-signed-artifacts'
      ORDER BY started_at DESC
      LIMIT 1
    `,
    prisma.$queryRaw<Array<{ finished_at: Date | null }>>`
      SELECT finished_at
      FROM data.signing_ops_job_runs
      WHERE job_name = 'reconcile-docuseal-signed-artifacts'
        AND ok = true
      ORDER BY finished_at DESC NULLS LAST
      LIMIT 1
    `,
  ])

  const last = lastRunRows[0]
  const lastOkAt = lastOkRows[0]?.finished_at
  const secondsSinceOk = lastOkAt
    ? Math.max(0, Math.floor((Date.now() - new Date(lastOkAt).getTime()) / 1000))
    : null

  const reconcile: ReconcileHealth = {
    backlog: toNumber(backlogRows[0]?.n),
    last_started_at: toIso(last?.started_at) ?? null,
    last_finished_at: toIso(last?.finished_at) ?? null,
    last_ok: last?.ok ?? null,
    last_error: last?.error_text ?? null,
    last_listed: toNumber(last?.listed),
    last_attempted: toNumber(last?.attempted),
    last_attached: toNumber(last?.attached),
    last_skipped: toNumber(last?.skipped),
    seconds_since_ok: secondsSinceOk,
  }

  const [
    sub7,
    sub30,
    outcomes,
    bridge,
    lowCredits,
    creditsTotal,
    pdfDlq,
    fail24,
    fail7,
    stuck,
    openNoDelivery,
    openArtifactFailed,
    spike,
  ] = await Promise.all([
    prisma.$queryRaw<Array<{ signing_provider: string; n: number | bigint }>>`
      SELECT signing_provider, count(*)::int AS n
      FROM data.signing_submissions
      WHERE created_at >= now() - interval '7 days'
      GROUP BY signing_provider
    `,
    prisma.$queryRaw<Array<{ signing_provider: string; n: number | bigint }>>`
      SELECT signing_provider, count(*)::int AS n
      FROM data.signing_submissions
      WHERE created_at >= now() - interval '30 days'
      GROUP BY signing_provider
    `,
    prisma.$queryRaw<Array<{ status: string; n: number | bigint }>>`
      SELECT status::text, count(*)::int AS n
      FROM data.signing_submissions
      WHERE created_at >= now() - interval '30 days'
      GROUP BY status
    `,
    prisma.$queryRaw<Array<{ kind: string; n: number | bigint }>>`
      SELECT
        CASE
          WHEN COALESCE((metadata->>'commercial_bridge')::boolean, false)
            THEN 'bridge'
          ELSE 'generic'
        END AS kind,
        count(*)::int AS n
      FROM data.signing_submissions
      WHERE created_at >= now() - interval '30 days'
      GROUP BY 1
    `,
    prisma.$queryRaw<Array<{ tenant_id: string; tenant_name: string; credits: number }>>`
      SELECT
        c.tenant_id::text,
        t.name AS tenant_name,
        c.signing_credits::int AS credits
      FROM data.tenant_signing_config c
      JOIN data.tenants t ON t.id = c.tenant_id
      WHERE c.mode = 'platform'
        AND c.signing_credits <= 5
      ORDER BY c.signing_credits ASC, t.name ASC
      LIMIT 20
    `,
    prisma.$queryRaw<Array<{ total: number | bigint }>>`
      SELECT COALESCE(sum(signing_credits), 0)::int AS total
      FROM data.tenant_signing_config
      WHERE mode = 'platform'
    `,
    prisma.$queryRaw<Array<{ n: number | bigint }>>`
      SELECT count(*)::int AS n
      FROM data.document_pdf_jobs
      WHERE is_dead_letter = true
        OR status = 'dead_letter'
    `,
    prisma.$queryRaw<
      Array<{ tenant_id: string; tenant_name: string | null; failures: number | bigint }>
    >`
      SELECT
        l.tenant_id::text,
        t.name AS tenant_name,
        count(*)::int AS failures
      FROM data.tenant_operation_logs l
      LEFT JOIN data.tenants t ON t.id = l.tenant_id
      WHERE l.integration_type IN ('signing', 'pdf_generation')
        AND l.status IN ('failed', 'dead_letter', 'degraded')
        AND l.created_at >= now() - interval '24 hours'
      GROUP BY l.tenant_id, t.name
      ORDER BY failures DESC
      LIMIT 10
    `,
    prisma.$queryRaw<
      Array<{ tenant_id: string; tenant_name: string | null; failures: number | bigint }>
    >`
      SELECT
        l.tenant_id::text,
        t.name AS tenant_name,
        count(*)::int AS failures
      FROM data.tenant_operation_logs l
      LEFT JOIN data.tenants t ON t.id = l.tenant_id
      WHERE l.integration_type IN ('signing', 'pdf_generation')
        AND l.status IN ('failed', 'dead_letter', 'degraded')
        AND l.created_at >= now() - interval '7 days'
      GROUP BY l.tenant_id, t.name
      ORDER BY failures DESC
      LIMIT 10
    `,
    prisma.$queryRaw<Array<{ n: number | bigint }>>`
      SELECT count(*)::int AS n
      FROM data.signing_submissions
      WHERE status IN ('pending', 'in_progress')
        AND created_at < now() - interval '6 hours'
        AND NOT COALESCE((metadata->>'superseded_by_switch')::boolean, false)
    `,
    prisma.$queryRaw<Array<{ n: number | bigint }>>`
      SELECT count(*)::int AS n
      FROM data.commercial_decision_requests r
      WHERE r.status = 'open'
        AND NOT EXISTS (
          SELECT 1
          FROM data.signing_submissions ss
          WHERE ss.metadata->>'decision_request_id' = r.id::text
            AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
            AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
            AND ss.status NOT IN ('cancelled', 'error', 'expired')
        )
    `,
    prisma.$queryRaw<Array<{ n: number | bigint }>>`
      SELECT count(*)::int AS n
      FROM data.commercial_decision_requests r
      WHERE r.status = 'open'
        AND EXISTS (
          SELECT 1
          FROM data.signing_submissions ss
          WHERE ss.metadata->>'decision_request_id' = r.id::text
            AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
            AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
            AND ss.metadata->>'artifact_status' = 'failed'
        )
    `,
    prisma.$queryRaw<
      Array<{
        tenant_id: string
        tenant_name: string | null
        events_24h: number | bigint
        avg_7d: number | bigint
      }>
    >`
      WITH daily AS (
        SELECT
          l.tenant_id,
          date_trunc('day', l.created_at) AS d,
          count(*)::int AS n
        FROM data.tenant_operation_logs l
        WHERE l.integration_type = 'signing'
          AND l.operation_code ILIKE '%webhook%'
          AND l.created_at >= now() - interval '7 days'
        GROUP BY 1, 2
      ),
      agg AS (
        SELECT
          tenant_id,
          COALESCE(sum(n) FILTER (WHERE d >= now() - interval '24 hours'), 0)::int AS events_24h,
          (COALESCE(avg(n), 0))::numeric AS avg_7d
        FROM daily
        GROUP BY tenant_id
      )
      SELECT
        a.tenant_id::text,
        t.name AS tenant_name,
        a.events_24h,
        round(a.avg_7d)::int AS avg_7d
      FROM agg a
      LEFT JOIN data.tenants t ON t.id = a.tenant_id
      WHERE a.events_24h > 0
        AND a.events_24h >= GREATEST(5, (a.avg_7d * 2)::int)
      ORDER BY a.events_24h DESC
      LIMIT 10
    `,
  ])

  const mapProvider = (rows: Array<{ signing_provider: string; n: number | bigint }>) => ({
    native: toNumber(rows.find((r) => r.signing_provider === 'native')?.n),
    docuseal: toNumber(rows.find((r) => r.signing_provider === 'docuseal')?.n),
  })

  const outcomesMap: Record<string, number> = {}
  for (const row of outcomes) outcomesMap[row.status] = toNumber(row.n)

  const stats: SigningOpsStats = {
    submissions_7d: mapProvider(sub7),
    submissions_30d: mapProvider(sub30),
    outcomes_30d: outcomesMap,
    bridge_vs_generic_30d: {
      bridge: toNumber(bridge.find((r) => r.kind === 'bridge')?.n),
      generic: toNumber(bridge.find((r) => r.kind === 'generic')?.n),
    },
    low_credit_tenants: lowCredits,
    platform_credits_total: toNumber(creditsTotal[0]?.total),
    pdf_dead_letters: toNumber(pdfDlq[0]?.n),
  }

  const anomalies: SigningOpsAnomalies = {
    top_failures_24h: fail24.map((r) => ({
      tenant_id: r.tenant_id,
      tenant_name: r.tenant_name,
      failures: toNumber(r.failures),
    })),
    top_failures_7d: fail7.map((r) => ({
      tenant_id: r.tenant_id,
      tenant_name: r.tenant_name,
      failures: toNumber(r.failures),
    })),
    stuck_submissions: toNumber(stuck[0]?.n),
    open_requests_no_delivery: toNumber(openNoDelivery[0]?.n),
    open_requests_artifact_failed: toNumber(openArtifactFailed[0]?.n),
    webhook_spike_tenants: spike.map((r) => ({
      tenant_id: r.tenant_id,
      tenant_name: r.tenant_name,
      events_24h: toNumber(r.events_24h),
      avg_7d: toNumber(r.avg_7d),
    })),
  }

  return { queues, reconcile, stats, anomalies }
}

export async function runSigningArtifactReconcileNow(
  limit = 20,
): Promise<{ ok: boolean; message?: string; body?: unknown }> {
  await assertBackoffice()

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!url || !key) {
    return { ok: false, message: 'Missing Supabase admin credentials' }
  }

  const res = await fetch(`${url}/functions/v1/reconcile-docuseal-signed-artifacts`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ limit: Math.max(1, Math.min(50, limit)) }),
  })

  const body = await res.json().catch(() => ({}))
  if (!res.ok) {
    return {
      ok: false,
      message:
        typeof (body as { error?: string }).error === 'string'
          ? (body as { error: string }).error
          : `HTTP ${res.status}`,
      body,
    }
  }
  return { ok: true, body }
}

export interface TenantSigningOpsSummary {
  unresolved_failures_7d: number
  submissions_30d_native: number
  submissions_30d_docuseal: number
  signing_credits: number | null
  artifact_backlog: number
}

export async function getTenantSigningOpsSummary(
  tenantId: string,
): Promise<TenantSigningOpsSummary> {
  await assertBackoffice()

  const [failRows, subRows, creditRows, backlogRows] = await Promise.all([
    prisma.$queryRaw<Array<{ n: number | bigint }>>`
      SELECT count(*)::int AS n
      FROM data.tenant_operation_logs
      WHERE tenant_id = ${tenantId}::uuid
        AND integration_type IN ('signing', 'pdf_generation')
        AND status IN ('failed', 'dead_letter', 'degraded')
        AND resolved_at IS NULL
        AND created_at >= now() - interval '7 days'
    `,
    prisma.$queryRaw<Array<{ signing_provider: string; n: number | bigint }>>`
      SELECT signing_provider, count(*)::int AS n
      FROM data.signing_submissions
      WHERE tenant_id = ${tenantId}::uuid
        AND created_at >= now() - interval '30 days'
      GROUP BY signing_provider
    `,
    prisma.$queryRaw<Array<{ signing_credits: number }>>`
      SELECT signing_credits::int AS signing_credits
      FROM data.tenant_signing_config
      WHERE tenant_id = ${tenantId}::uuid
      LIMIT 1
    `,
    prisma.$queryRaw<Array<{ n: number | bigint }>>`
      SELECT count(*)::int AS n
      FROM data.signing_submissions ss
      WHERE ss.tenant_id = ${tenantId}::uuid
        AND ss.status = 'completed'
        AND ss.result_document_version_id IS NULL
        AND COALESCE((ss.metadata->>'commercial_bridge')::boolean, false)
        AND NOT COALESCE((ss.metadata->>'superseded_by_switch')::boolean, false)
        AND COALESCE(ss.metadata->>'artifact_status', 'failed') IN ('pending', 'failed')
    `,
  ])

  return {
    unresolved_failures_7d: toNumber(failRows[0]?.n),
    submissions_30d_native: toNumber(
      subRows.find((r) => r.signing_provider === 'native')?.n,
    ),
    submissions_30d_docuseal: toNumber(
      subRows.find((r) => r.signing_provider === 'docuseal')?.n,
    ),
    signing_credits: creditRows[0]?.signing_credits ?? null,
    artifact_backlog: toNumber(backlogRows[0]?.n),
  }
}
