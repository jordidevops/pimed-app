'use server'

import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

export interface MapsJsClientErrorRow {
  tenant_id: string
  tenant_name: string | null
  category: string
  code: string
  origin: string
  first_seen_at: string
  last_seen_at: string
  count: number
}

async function assertAdmin(allowedRoles: ('admin' | 'support')[] = ['admin', 'support']) {
  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()
  if (error || !user) throw new Error('Unauthenticated')

  const role = user.app_metadata?.role as string | undefined
  if (!role || !allowedRoles.includes(role as 'admin' | 'support')) {
    throw new Error(`Forbidden: requires one of [${allowedRoles.join(', ')}]`)
  }

  return { user, role: role as 'admin' | 'support' }
}

export async function getMapsJsClientErrorsSummary(
  limit: number = 200,
  tenantId?: string,
): Promise<MapsJsClientErrorRow[]> {
  await assertAdmin(['admin', 'support'])

  const rows = tenantId
    ? await prisma.$queryRaw<
        Array<{
          tenant_id: string
          tenant_name: string | null
          category: string
          code: string
          origin: string
          first_seen_at: Date | string
          last_seen_at: Date | string
          count: bigint | number
        }>
      >`
        SELECT
          e.tenant_id,
          t.name AS tenant_name,
          e.category,
          e.code,
          e.origin,
          e.first_seen_at,
          e.last_seen_at,
          e.count
        FROM data.maps_js_client_errors e
        LEFT JOIN data.tenants t ON t.id = e.tenant_id
        WHERE e.tenant_id = ${tenantId}::uuid
        ORDER BY e.last_seen_at DESC
        LIMIT ${limit}
      `
    : await prisma.$queryRaw<
        Array<{
          tenant_id: string
          tenant_name: string | null
          category: string
          code: string
          origin: string
          first_seen_at: Date | string
          last_seen_at: Date | string
          count: bigint | number
        }>
      >`
        SELECT
          e.tenant_id,
          t.name AS tenant_name,
          e.category,
          e.code,
          e.origin,
          e.first_seen_at,
          e.last_seen_at,
          e.count
        FROM data.maps_js_client_errors e
        LEFT JOIN data.tenants t ON t.id = e.tenant_id
        ORDER BY e.last_seen_at DESC
        LIMIT ${limit}
      `

  return rows.map((e) => ({
    tenant_id: e.tenant_id,
    tenant_name: e.tenant_name,
    category: e.category,
    code: e.code,
    origin: e.origin,
    first_seen_at:
      typeof e.first_seen_at === 'string' ? e.first_seen_at : e.first_seen_at.toISOString(),
    last_seen_at:
      typeof e.last_seen_at === 'string' ? e.last_seen_at : e.last_seen_at.toISOString(),
    count: Number(e.count ?? 0),
  }))
}

