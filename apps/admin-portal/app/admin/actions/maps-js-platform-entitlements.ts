'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'
import { createSupabaseAdminClient } from '@/lib/supabase/admin'

export type MapsJsPlatformEntitlementRow = {
  tenant_id: string
  tenant_name: string | null
  activated_at: string
  expires_at: string | null
  /** Computed from dates (expires_at null = never expires). */
  is_active_by_dates: boolean
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

function isActiveByDates(expiresAt: string | null, now = Date.now()): boolean {
  if (!expiresAt) return true
  const t = new Date(expiresAt).getTime()
  return Number.isFinite(t) && t > now
}

export async function getTenantMapsJsPlatformEntitlements(
  tenantId?: string,
): Promise<MapsJsPlatformEntitlementRow[]> {
  await assertAdmin(['admin', 'support'])

  const rows = tenantId
    ? await prisma.$queryRaw<
        Array<{
          tenant_id: string
          tenant_name: string | null
          activated_at: Date | string
          expires_at: Date | string | null
        }>
      >`
        SELECT
          e.tenant_id,
          t.name AS tenant_name,
          e.activated_at,
          e.expires_at
        FROM data.tenant_maps_js_platform_entitlements e
        LEFT JOIN data.tenants t ON t.id = e.tenant_id
        WHERE e.tenant_id = ${tenantId}::uuid
        ORDER BY e.activated_at DESC
        LIMIT 1
      `
    : await prisma.$queryRaw<
        Array<{
          tenant_id: string
          tenant_name: string | null
          activated_at: Date | string
          expires_at: Date | string | null
        }>
      >`
        SELECT
          e.tenant_id,
          t.name AS tenant_name,
          e.activated_at,
          e.expires_at
        FROM data.tenant_maps_js_platform_entitlements e
        LEFT JOIN data.tenants t ON t.id = e.tenant_id
        ORDER BY e.activated_at DESC
        LIMIT 200
      `

  return rows.map((r) => {
    const activated_at =
      typeof r.activated_at === 'string' ? r.activated_at : r.activated_at.toISOString()
    const expires_at = r.expires_at
      ? typeof r.expires_at === 'string'
        ? r.expires_at
        : r.expires_at.toISOString()
      : null
    return {
      tenant_id: r.tenant_id,
      tenant_name: r.tenant_name,
      activated_at,
      expires_at,
      is_active_by_dates: isActiveByDates(expires_at),
    }
  })
}

export async function getActiveTenantMapsJsByokKeys(
  tenantId?: string,
): Promise<Array<{ tenant_id: string; tenant_name: string | null; active_since: string }>> {
  await assertAdmin(['admin', 'support'])

  const rows = tenantId
    ? await prisma.$queryRaw<
        Array<{
          tenant_id: string
          tenant_name: string | null
          active_since: Date | string
        }>
      >`
        SELECT
          ts.tenant_id,
          t.name AS tenant_name,
          COALESCE(ts.last_rotated_at, ts.created_at) AS active_since
        FROM data.tenant_secret_refs ts
        LEFT JOIN data.tenants t ON t.id = ts.tenant_id
        WHERE ts.secret_type = 'maps_js_api_key'
          AND ts.provider = 'google'
          AND ts.rotation_status = 'active'
          AND ts.tenant_id = ${tenantId}::uuid
        ORDER BY active_since DESC
        LIMIT 1
      `
    : await prisma.$queryRaw<
        Array<{
          tenant_id: string
          tenant_name: string | null
          active_since: Date | string
        }>
      >`
        SELECT
          ts.tenant_id,
          t.name AS tenant_name,
          COALESCE(ts.last_rotated_at, ts.created_at) AS active_since
        FROM data.tenant_secret_refs ts
        LEFT JOIN data.tenants t ON t.id = ts.tenant_id
        WHERE ts.secret_type = 'maps_js_api_key'
          AND ts.provider = 'google'
          AND ts.rotation_status = 'active'
        ORDER BY active_since DESC
        LIMIT 200
      `

  return rows.map((r) => ({
    tenant_id: r.tenant_id,
    tenant_name: r.tenant_name,
    active_since:
      typeof r.active_since === 'string' ? r.active_since : r.active_since.toISOString(),
  }))
}

export async function getTenantsForMapsJsEntitlements(): Promise<Array<{ id: string; name: string }>> {
  await assertAdmin(['admin', 'support'])

  const rows = await prisma.$queryRaw<Array<{ id: string; name: string }>>`
    SELECT id, name
    FROM data.tenants
    ORDER BY name ASC
    LIMIT 200
  `

  return rows
}

export async function activateMapsJsPlatformEntitlement(formData: FormData): Promise<{ ok: boolean; message: string }> {
  await assertAdmin(['admin'])

  const tenantId = String(formData.get('tenantId') ?? '').trim()
  const daysRaw = formData.get('days') ?? '30'
  const days = Math.max(1, Math.min(365, Number(daysRaw)))

  if (!tenantId) return { ok: false, message: 'Missing tenantId' }

  const expiresAt = new Date(Date.now() + days * 24 * 60 * 60 * 1000)

  await prisma.$executeRaw`
    INSERT INTO data.tenant_maps_js_platform_entitlements (tenant_id, activated_at, expires_at)
    VALUES (${tenantId}::uuid, now(), ${expiresAt.toISOString()}::timestamptz)
    ON CONFLICT (tenant_id) DO UPDATE SET
      activated_at = now(),
      expires_at = EXCLUDED.expires_at,
      updated_at = now()
  `

  revalidatePath('/dashboard/settings/maps-js-platform-entitlements')
  revalidatePath(`/dashboard/tenants/${tenantId}`)
  return { ok: true, message: 'Activated' }
}

export async function deactivateMapsJsPlatformEntitlement(formData: FormData): Promise<{ ok: boolean; message: string }> {
  await assertAdmin(['admin'])

  const tenantId = String(formData.get('tenantId') ?? '').trim()
  if (!tenantId) return { ok: false, message: 'Missing tenantId' }

  await prisma.$executeRaw`
    DELETE FROM data.tenant_maps_js_platform_entitlements
    WHERE tenant_id = ${tenantId}::uuid
  `

  revalidatePath('/dashboard/settings/maps-js-platform-entitlements')
  revalidatePath(`/dashboard/tenants/${tenantId}`)
  return { ok: true, message: 'Deactivated' }
}

/** Verify entitlement active state against Postgres (dates window). */
export async function verifyMapsJsPlatformEntitlementActive(
  tenantId: string,
): Promise<{ ok: boolean; is_active: boolean; activated_at: string | null; expires_at: string | null; message: string }> {
  await assertAdmin(['admin', 'support'])

  const rows = await prisma.$queryRaw<
    Array<{
      activated_at: Date | string
      expires_at: Date | string | null
      is_active: boolean
    }>
  >`
    SELECT
      e.activated_at,
      e.expires_at,
      (e.expires_at IS NULL OR e.expires_at > now()) AS is_active
    FROM data.tenant_maps_js_platform_entitlements e
    WHERE e.tenant_id = ${tenantId}::uuid
    LIMIT 1
  `

  const row = rows[0]
  if (!row) {
    return {
      ok: true,
      is_active: false,
      activated_at: null,
      expires_at: null,
      message: 'Sense fila d’entitlement a Postgres',
    }
  }

  const activated_at =
    typeof row.activated_at === 'string' ? row.activated_at : row.activated_at.toISOString()
  const expires_at = row.expires_at
    ? typeof row.expires_at === 'string'
      ? row.expires_at
      : row.expires_at.toISOString()
    : null

  return {
    ok: true,
    is_active: Boolean(row.is_active),
    activated_at,
    expires_at,
    message: row.is_active ? 'Actiu a Postgres' : 'Inactiu a Postgres (caducat o sense fila vàlida)',
  }
}

export async function getMapsJsPlatformVaultKeyStatus(): Promise<{
  present: boolean
  registry_key_version: number | null
  last_rotated_at: string | null
}> {
  await assertAdmin(['admin', 'support'])

  let present = false
  const admin = createSupabaseAdminClient()
  const { data, error } = await admin.rpc('has_maps_js_platform_api_key_service')
  if (!error) {
    present = Boolean(data)
  }

  const registry = await prisma.$queryRaw<
    Array<{ key_version: number; last_rotated_at: Date | string | null }>
  >`
    SELECT key_version, last_rotated_at
    FROM data.platform_secret_registry
    WHERE secret_key = 'maps_js_platform_trial_api_key'
    LIMIT 1
  `
  const reg = registry[0]

  return {
    present,
    registry_key_version: reg?.key_version ?? null,
    last_rotated_at: reg?.last_rotated_at
      ? typeof reg.last_rotated_at === 'string'
        ? reg.last_rotated_at
        : reg.last_rotated_at.toISOString()
      : null,
  }
}

export async function upsertMapsJsPlatformVaultKey(
  apiKey: string,
): Promise<{ ok: boolean; message: string }> {
  await assertAdmin(['admin'])

  const trimmed = apiKey.trim()
  if (trimmed.length < 20) {
    return { ok: false, message: 'La clau és massa curta' }
  }

  const admin = createSupabaseAdminClient()
  const { data, error } = await admin.rpc('upsert_maps_js_platform_api_key_service', {
    p_api_key: trimmed,
  })

  if (error) {
    return { ok: false, message: error.message }
  }

  revalidatePath('/dashboard/settings/maps-js-platform-entitlements')
  return {
    ok: true,
    message: typeof data === 'object' && data && 'status' in data ? 'Clau desada al Vault' : 'OK',
  }
}

const PLATFORM_MAP_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_\-]{5,100}$/

export async function getMapsJsPlatformMapId(): Promise<{ map_id: string | null }> {
  await assertAdmin(['admin', 'support'])

  const rows = await prisma.$queryRaw<Array<{ settings: Record<string, unknown> | null }>>`
    SELECT settings
    FROM data.system_settings
    WHERE module = 'maps_js'
    LIMIT 1
  `

  const raw = rows[0]?.settings?.map_id
  const mapId = typeof raw === 'string' && PLATFORM_MAP_ID_RE.test(raw.trim()) ? raw.trim() : null
  return { map_id: mapId }
}

export async function upsertMapsJsPlatformMapId(
  mapId: string,
): Promise<{ ok: boolean; message: string }> {
  const { user } = await assertAdmin(['admin'])

  const trimmed = mapId.trim()
  if (trimmed && !PLATFORM_MAP_ID_RE.test(trimmed)) {
    return { ok: false, message: 'Format de Map ID invàlid' }
  }

  const next = { map_id: trimmed || null }

  await prisma.$executeRaw`
    INSERT INTO data.system_settings (module, settings, updated_by)
    VALUES ('maps_js', ${JSON.stringify(next)}::jsonb, ${user.id}::uuid)
    ON CONFLICT (module) DO UPDATE SET
      settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now(),
      updated_by = EXCLUDED.updated_by
  `

  revalidatePath('/dashboard/settings/maps-js-platform-entitlements')
  return {
    ok: true,
    message: trimmed ? 'Map ID de plataforma desat' : 'Map ID de plataforma esborrat',
  }
}
