'use server'

import { Prisma } from '@prisma/client'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

interface QueueMetricRow {
  queue_name: string
  queue_length: number
  newest_msg_age_sec: number
  oldest_msg_age_sec: number
  total_messages: number
  scrape_time: Date | string
}

interface ArchiveCountRow {
  archive_count: number
}

export interface QueueMetric {
  queue_name: string
  queue_length: number
  newest_msg_age_sec: number
  oldest_msg_age_sec: number
  total_messages: number
  scrape_time: string
}

export interface QueueMetricsResult {
  metrics: QueueMetric
  archive_count: number
  available: boolean
  error_message?: string
}

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

function toNumber(value: unknown): number {
  if (typeof value === 'number') return value
  if (typeof value === 'bigint') return Number(value)
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}

function toIsoString(value: Date | string): string {
  if (value instanceof Date) return value.toISOString()
  return new Date(value).toISOString()
}

function isPgmqPermissionError(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false

  const message =
    typeof (error as { message?: unknown }).message === 'string'
      ? (error as { message: string }).message
      : ''

  return (
    message.includes('permission denied for schema pgmq') ||
    message.includes('Code: `42501`')
  )
}

function getFallbackMetrics(errorMessage?: string): QueueMetricsResult {
  return {
    metrics: {
      queue_name: 'email_send_queue',
      queue_length: 0,
      newest_msg_age_sec: 0,
      oldest_msg_age_sec: 0,
      total_messages: 0,
      scrape_time: new Date().toISOString(),
    },
    archive_count: 0,
    available: false,
    error_message: errorMessage,
  }
}

export async function getQueueMetrics(): Promise<QueueMetricsResult> {
  await assertBackoffice()

  try {
    const [metricRows, archiveRows] = await Promise.all([
      prisma.$queryRaw<QueueMetricRow[]>`
        SELECT
          queue_name,
          queue_length,
          newest_msg_age_sec,
          oldest_msg_age_sec,
          total_messages,
          scrape_time
        FROM pgmq.metrics('email_send_queue');
      `,
      prisma.$queryRaw<ArchiveCountRow[]>`
        SELECT count(*)::int as archive_count
        FROM pgmq.a_email_send_queue;
      `,
    ])

    const metric = metricRows[0]
    if (!metric) {
      return getFallbackMetrics('No s\'han pogut obtenir mètriques de la cua email_send_queue')
    }

    return {
      metrics: {
        queue_name: metric.queue_name,
        queue_length: toNumber(metric.queue_length),
        newest_msg_age_sec: toNumber(metric.newest_msg_age_sec),
        oldest_msg_age_sec: toNumber(metric.oldest_msg_age_sec),
        total_messages: toNumber(metric.total_messages),
        scrape_time: toIsoString(metric.scrape_time),
      },
      archive_count: toNumber(archiveRows[0]?.archive_count ?? 0),
      available: true,
    }
  } catch (error: unknown) {
    if (isPgmqPermissionError(error)) {
      return getFallbackMetrics(
        'No hi ha permisos sobre l\'schema pgmq per consultar mètriques de la cua.',
      )
    }

    throw error
  }
}

// ---------------------------------------------------------------------------
// Active queue messages
// ---------------------------------------------------------------------------

interface QueueMessageRow {
  msg_id: bigint
  read_ct: number
  enqueued_at: Date | string
  vt: Date | string
  message: unknown
  tenant_name: string | null
}

export interface ActiveQueueMessage {
  msg_id: number
  read_ct: number
  enqueued_at: string
  vt: string
  email_log_id: string | null
  tenant_id: string | null
  tenant_name: string | null
  priority: number | null
  scheduled_at: string | null
  time_in_queue_ms: number
}

export interface GetQueueMessagesParams {
  page?: number
  pageSize?: number
  sortColumn?: 'msg_id' | 'enqueued_at' | 'vt'
  sortAsc?: boolean
  search?: string
}

export interface QueueMessagesResult {
  messages: ActiveQueueMessage[]
  total: number
  page: number
  pageSize: number
}

export async function getActiveQueueMessages(
  params: GetQueueMessagesParams = {},
): Promise<QueueMessagesResult> {
  await assertBackoffice()

  const page = Math.max(1, params.page ?? 1)
  const pageSize = Math.min(100, Math.max(10, params.pageSize ?? 20))
  const offset = (page - 1) * pageSize

  const SORT_COLS: Record<string, string> = {
    msg_id: 'q.msg_id',
    enqueued_at: 'q.enqueued_at',
    vt: 'q.vt',
  }
  const sortColExpr = SORT_COLS[params.sortColumn ?? 'msg_id'] ?? 'q.msg_id'
  const sortDirection = params.sortAsc ? Prisma.raw('ASC') : Prisma.raw('DESC')

  const searchIlike: string | null = params.search?.trim()
    ? `%${params.search.trim()}%`
    : null

  try {
    const [rows, countResult] = await Promise.all([
      prisma.$queryRaw<QueueMessageRow[]>(Prisma.sql`
        SELECT q.msg_id, q.read_ct, q.enqueued_at, q.vt, q.message,
               t.name AS tenant_name
        FROM pgmq.q_email_send_queue q
        LEFT JOIN data.tenants t ON t.id::text = (q.message->>'tenant_id')
        WHERE (${searchIlike}::text IS NULL
               OR t.name ILIKE ${searchIlike}
               OR (q.message->>'email_log_id') ILIKE ${searchIlike})
        ORDER BY ${Prisma.raw(sortColExpr)} ${sortDirection}
        LIMIT ${pageSize} OFFSET ${offset}
      `),
      prisma.$queryRaw<[{ count: number }]>`
        SELECT COUNT(*)::int AS count
        FROM pgmq.q_email_send_queue q
        LEFT JOIN data.tenants t ON t.id::text = (q.message->>'tenant_id')
        WHERE (${searchIlike}::text IS NULL
               OR t.name ILIKE ${searchIlike}
               OR (q.message->>'email_log_id') ILIKE ${searchIlike})
      `,
    ])

    const messages = rows.map((row) => {
      const msg = row.message && typeof row.message === 'object'
        ? (row.message as Record<string, unknown>)
        : {}

      const scheduledAt = msg.scheduled_at
      return {
        msg_id: Number(row.msg_id),
        read_ct: toNumber(row.read_ct),
        enqueued_at: toIsoString(row.enqueued_at),
        vt: toIsoString(row.vt),
        email_log_id: typeof msg.email_log_id === 'string' ? msg.email_log_id : null,
        tenant_id: typeof msg.tenant_id === 'string' ? msg.tenant_id : null,
        tenant_name: typeof row.tenant_name === 'string' ? row.tenant_name : null,
        priority: msg.priority !== undefined && msg.priority !== null
          ? toNumber(msg.priority)
          : null,
        scheduled_at: scheduledAt
          ? toIsoString(scheduledAt as Date | string)
          : null,
        time_in_queue_ms: Date.now() - new Date(toIsoString(row.enqueued_at)).getTime(),
      }
    })

    return {
      messages,
      total: toNumber(countResult[0]?.count ?? 0),
      page,
      pageSize,
    }
  } catch (error: unknown) {
    if (isPgmqPermissionError(error)) {
      return { messages: [], total: 0, page, pageSize }
    }
    throw error
  }
}

export interface PurgeQueueResult {
  purged: number
}

export async function purgeQueue(): Promise<PurgeQueueResult> {
  await assertBackoffice()

  try {
    const rows = await prisma.$queryRaw<Array<{ purge_queue: number }>>`
      SELECT pgmq.purge_queue('email_send_queue') AS purge_queue;
    `

    return { purged: toNumber(rows[0]?.purge_queue ?? 0) }
  } catch (error: unknown) {
    if (isPgmqPermissionError(error)) {
      throw new Error('Permís denegat: cal accés a pgmq per purgar la cua.')
    }
    throw error
  }
}
