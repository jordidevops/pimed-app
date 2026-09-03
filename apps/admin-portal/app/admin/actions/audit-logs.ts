'use server'

import { Prisma } from '@prisma/client'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

// ---------------------------------------------------------------------------
// Auth guard (same pattern as email-logs.ts)
// ---------------------------------------------------------------------------

async function assertBackoffice() {
  const supabase = await createSupabaseServerClient()
  const { data: { user }, error } = await supabase.auth.getUser()
  if (error || !user) throw new Error('Unauthenticated')
  const role = user.app_metadata?.role as string | undefined
  if (role !== 'admin' && role !== 'support') throw new Error('Forbidden')
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface AuditLogRow {
  id: string
  tenant_id: string | null
  tenant_name: string | null
  site_id: string | null
  site_name: string | null
  user_id: string | null
  user_email: string | null
  user_name: string | null
  action: string
  entity_type: string | null
  entity_id: string | null
  ip_address: string | null
  created_at: string
}

export interface AuditLogDetail extends AuditLogRow {
  payload: Record<string, unknown> | null
}

export interface GetAuditLogsParams {
  page?: number
  pageSize?: number
  dateFrom?: string
  dateTo?: string
  tenantId?: string
  action?: string
  entityType?: string
  search?: string
  sortColumn?: string
  sortAsc?: boolean
}

export interface AuditLogsResult {
  rows: AuditLogRow[]
  total: number
  page: number
  pageSize: number
}

export interface AuditDayPoint {
  date: string
  count: number
}

export interface AuditActionPoint {
  action: string
  count: number
}

export interface AuditTenantPoint {
  tenant_id: string
  tenant_name: string | null
  count: number
}

export interface AuditLogsStats {
  perDay: AuditDayPoint[]
  topActions: AuditActionPoint[]
  topTenants: AuditTenantPoint[]
}

export interface TenantOptionForAudit {
  id: string
  name: string
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function dateNDaysAgo(n: number): Date {
  const d = new Date()
  d.setDate(d.getDate() - n)
  d.setHours(0, 0, 0, 0)
  return d
}

function normalizeUuidOrNull(input?: string): string | null {
  const value = input?.trim()
  if (!value) return null
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
    ? value
    : null
}

const SORTABLE_COLUMNS: Record<string, string> = {
  created_at:  'al.created_at',
  action:      'al.action',
  entity_type: 'al.entity_type',
  tenant_name: 't.name',
}

// ---------------------------------------------------------------------------
// getAuditLogs — server-side filtered, sorted, paginated
// ---------------------------------------------------------------------------

export async function getAuditLogs(
  params: GetAuditLogsParams = {},
): Promise<AuditLogsResult> {
  await assertBackoffice()

  const page     = Math.max(1, params.page ?? 1)
  const pageSize = Math.min(200, Math.max(10, params.pageSize ?? 50))
  const offset   = (page - 1) * pageSize

  const dateFrom         = params.dateFrom ? new Date(params.dateFrom) : dateNDaysAgo(7)
  const dateTo           = params.dateTo ? new Date(params.dateTo + 'T23:59:59.999Z') : new Date()
  const tenantFilterUuid = normalizeUuidOrNull(params.tenantId)
  const actionFilter     = params.action?.trim()     ? `%${params.action.trim()}%`     : null
  const entityTypeFilter = params.entityType?.trim() ? `%${params.entityType.trim()}%` : null
  const searchLike       = params.search?.trim()     ? `%${params.search.trim()}%`     : null

  const sortColExpr = SORTABLE_COLUMNS[params.sortColumn ?? 'created_at'] ?? 'al.created_at'
  const sortDir     = params.sortAsc ? Prisma.raw('ASC') : Prisma.raw('DESC')

  type RawRow = {
    id: string
    tenant_id: string | null
    tenant_name: string | null
    site_id: string | null
    site_name: string | null
    user_id: string | null
    user_email: string | null
    user_name: string | null
    action: string
    entity_type: string | null
    entity_id: string | null
    ip_address: string | null
    created_at: Date
  }

  const rows = await prisma.$queryRaw<RawRow[]>(Prisma.sql`
    SELECT
      al.id::text          AS id,
      al.tenant_id::text   AS tenant_id,
      t.name               AS tenant_name,
      al.site_id::text     AS site_id,
      s.name               AS site_name,
      al.user_id::text     AS user_id,
      p.email              AS user_email,
      p.full_name          AS user_name,
      al.action,
      al.entity_type,
      al.entity_id::text   AS entity_id,
      host(al.ip_address)  AS ip_address,
      al.created_at
    FROM data.audit_logs al
    LEFT JOIN data.tenants  t ON t.id = al.tenant_id
    LEFT JOIN data.sites    s ON s.id = al.site_id
    LEFT JOIN data.profiles p ON p.id = al.user_id
    WHERE al.created_at >= ${dateFrom}
      AND al.created_at <= ${dateTo}
      AND (${tenantFilterUuid}::uuid IS NULL OR al.tenant_id = ${tenantFilterUuid}::uuid)
      AND (${actionFilter}::text IS NULL OR al.action ILIKE ${actionFilter})
      AND (${entityTypeFilter}::text IS NULL OR al.entity_type ILIKE ${entityTypeFilter})
      AND (
        ${searchLike}::text IS NULL
        OR al.action ILIKE ${searchLike}
        OR al.entity_id::text ILIKE ${searchLike}
        OR p.email ILIKE ${searchLike}
        OR al.payload::text ILIKE ${searchLike}
      )
    ORDER BY ${Prisma.raw(sortColExpr)} ${sortDir}
    LIMIT ${pageSize} OFFSET ${offset}
  `)

  const countResult = await prisma.$queryRaw<[{ count: number }]>(Prisma.sql`
    SELECT COUNT(*)::int AS count
    FROM data.audit_logs al
    LEFT JOIN data.profiles p ON p.id = al.user_id
    WHERE al.created_at >= ${dateFrom}
      AND al.created_at <= ${dateTo}
      AND (${tenantFilterUuid}::uuid IS NULL OR al.tenant_id = ${tenantFilterUuid}::uuid)
      AND (${actionFilter}::text IS NULL OR al.action ILIKE ${actionFilter})
      AND (${entityTypeFilter}::text IS NULL OR al.entity_type ILIKE ${entityTypeFilter})
      AND (
        ${searchLike}::text IS NULL
        OR al.action ILIKE ${searchLike}
        OR al.entity_id::text ILIKE ${searchLike}
        OR p.email ILIKE ${searchLike}
        OR al.payload::text ILIKE ${searchLike}
      )
  `)

  return {
    rows: rows.map((r) => ({
      id:          r.id,
      tenant_id:   r.tenant_id,
      tenant_name: r.tenant_name,
      site_id:     r.site_id,
      site_name:   r.site_name,
      user_id:     r.user_id,
      user_email:  r.user_email,
      user_name:   r.user_name,
      action:      r.action,
      entity_type: r.entity_type,
      entity_id:   r.entity_id,
      ip_address:  r.ip_address,
      created_at:  r.created_at instanceof Date ? r.created_at.toISOString() : String(r.created_at),
    })),
    total:    countResult[0]?.count ?? 0,
    page,
    pageSize,
  }
}

// ---------------------------------------------------------------------------
// getAuditLogDetail — full single log including payload
// ---------------------------------------------------------------------------

export async function getAuditLogDetail(id: string): Promise<AuditLogDetail | null> {
  await assertBackoffice()

  // Validate UUID format to prevent SQL injection beyond parameterized queries
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    return null
  }

  type RawDetailRow = {
    id: string
    tenant_id: string | null
    tenant_name: string | null
    site_id: string | null
    site_name: string | null
    user_id: string | null
    user_email: string | null
    user_name: string | null
    action: string
    entity_type: string | null
    entity_id: string | null
    ip_address: string | null
    payload: unknown
    created_at: Date
  }

  const rows = await prisma.$queryRaw<RawDetailRow[]>`
    SELECT
      al.id::text          AS id,
      al.tenant_id::text   AS tenant_id,
      t.name               AS tenant_name,
      al.site_id::text     AS site_id,
      s.name               AS site_name,
      al.user_id::text     AS user_id,
      p.email              AS user_email,
      p.full_name          AS user_name,
      al.action,
      al.entity_type,
      al.entity_id::text   AS entity_id,
      host(al.ip_address)  AS ip_address,
      al.payload,
      al.created_at
    FROM data.audit_logs al
    LEFT JOIN data.tenants  t ON t.id = al.tenant_id
    LEFT JOIN data.sites    s ON s.id = al.site_id
    LEFT JOIN data.profiles p ON p.id = al.user_id
    WHERE al.id = ${id}::uuid
  `

  if (rows.length === 0) return null
  const r = rows[0]

  return {
    id:          r.id,
    tenant_id:   r.tenant_id,
    tenant_name: r.tenant_name,
    site_id:     r.site_id,
    site_name:   r.site_name,
    user_id:     r.user_id,
    user_email:  r.user_email,
    user_name:   r.user_name,
    action:      r.action,
    entity_type: r.entity_type,
    entity_id:   r.entity_id,
    ip_address:  r.ip_address,
    payload:     r.payload as Record<string, unknown> | null,
    created_at:  r.created_at instanceof Date ? r.created_at.toISOString() : String(r.created_at),
  }
}

// ---------------------------------------------------------------------------
// getAuditStats — aggregates for charts
// ---------------------------------------------------------------------------

export async function getAuditStats(params: {
  dateFrom?: string
  dateTo?: string
  tenantId?: string
} = {}): Promise<AuditLogsStats> {
  await assertBackoffice()

  const dateFrom     = params.dateFrom ? new Date(params.dateFrom) : dateNDaysAgo(7)
  const dateTo       = params.dateTo ? new Date(params.dateTo + 'T23:59:59.999Z') : new Date()
  const tenantFilterUuid = normalizeUuidOrNull(params.tenantId)

  const [perDay, topActions, topTenants] = await Promise.all([
    prisma.$queryRaw<AuditDayPoint[]>(Prisma.sql`
      SELECT
        to_char(al.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD') AS date,
        COUNT(*)::int AS count
      FROM data.audit_logs al
      WHERE al.created_at >= ${dateFrom}
        AND al.created_at <= ${dateTo}
        AND (${tenantFilterUuid}::uuid IS NULL OR al.tenant_id = ${tenantFilterUuid}::uuid)
      GROUP BY 1
      ORDER BY 1 ASC
    `),
    prisma.$queryRaw<AuditActionPoint[]>(Prisma.sql`
      SELECT
        al.action,
        COUNT(*)::int AS count
      FROM data.audit_logs al
      WHERE al.created_at >= ${dateFrom}
        AND al.created_at <= ${dateTo}
        AND (${tenantFilterUuid}::uuid IS NULL OR al.tenant_id = ${tenantFilterUuid}::uuid)
      GROUP BY al.action
      ORDER BY count DESC
      LIMIT 10
    `),
    prisma.$queryRaw<AuditTenantPoint[]>(Prisma.sql`
      SELECT
        al.tenant_id::text AS tenant_id,
        t.name             AS tenant_name,
        COUNT(*)::int      AS count
      FROM data.audit_logs al
      LEFT JOIN data.tenants t ON t.id = al.tenant_id
      WHERE al.created_at >= ${dateFrom}
        AND al.created_at <= ${dateTo}
        AND al.tenant_id IS NOT NULL
      GROUP BY al.tenant_id, t.name
      ORDER BY count DESC
      LIMIT 10
    `),
  ])

  return { perDay, topActions, topTenants }
}

// ---------------------------------------------------------------------------
// getTenantOptionsForAudit
// ---------------------------------------------------------------------------

export async function getTenantOptionsForAudit(): Promise<TenantOptionForAudit[]> {
  await assertBackoffice()
  const rows = await prisma.$queryRaw<Array<{ id: string; name: string }>>`
    SELECT id::text AS id, name
    FROM data.tenants
    ORDER BY name ASC
    LIMIT 500
  `
  return rows
}

// ---------------------------------------------------------------------------
// exportAuditLogsCsv — respects active filters, max 5000 rows
// ---------------------------------------------------------------------------

export async function exportAuditLogsCsv(
  params: Omit<GetAuditLogsParams, 'page' | 'pageSize'>,
): Promise<string> {
  const result = await getAuditLogs({ ...params, page: 1, pageSize: 5000 })

  const headers: (keyof AuditLogRow)[] = [
    'id', 'created_at', 'action', 'entity_type', 'entity_id',
    'tenant_id', 'tenant_name', 'site_id', 'site_name',
    'user_id', 'user_email', 'user_name', 'ip_address',
  ]

  const escape = (v: string | null | undefined): string => {
    if (v == null) return ''
    const s = String(v)
    return s.includes(',') || s.includes('"') || s.includes('\n')
      ? `"${s.replace(/"/g, '""')}"`
      : s
  }

  const lines = [
    headers.join(','),
    ...result.rows.map((r) =>
      headers.map((h) => escape(r[h] as string | null)).join(','),
    ),
  ]

  return lines.join('\n')
}
