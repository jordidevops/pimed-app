'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface GeocodingModuleSettings {
  nominatim_enabled: boolean
  nominatim_global_max_per_second: number
  nominatim_global_max_per_minute: number
}

export interface GeocodingOpsAlertRow {
  id: string
  tenant_id: string | null
  tenant_name: string | null
  provider_key: string | null
  usage_date: string
  blocked_requests: number
  threshold: number
  reason: string | null
  created_at: string
}

export interface GeocodingOpsSummary {
  settings: GeocodingModuleSettings
  second_used: number
  minute_used: number
  today: {
    success: number
    cached: number
    blocked: number
    provider_error: number
    network_error: number
  }
  upstream_429_today: number
  alerts: GeocodingOpsAlertRow[]
}

const GEOCODING_DEFAULTS: GeocodingModuleSettings = {
  nominatim_enabled: true,
  nominatim_global_max_per_second: 1,
  nominatim_global_max_per_minute: 50,
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

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

function mergeSettings(raw: Partial<GeocodingModuleSettings> | null | undefined): GeocodingModuleSettings {
  return {
    nominatim_enabled: raw?.nominatim_enabled ?? GEOCODING_DEFAULTS.nominatim_enabled,
    nominatim_global_max_per_second: Math.max(
      1,
      Number(raw?.nominatim_global_max_per_second ?? GEOCODING_DEFAULTS.nominatim_global_max_per_second),
    ),
    nominatim_global_max_per_minute: Math.max(
      1,
      Number(raw?.nominatim_global_max_per_minute ?? GEOCODING_DEFAULTS.nominatim_global_max_per_minute),
    ),
  }
}

async function readGeocodingSettings(): Promise<GeocodingModuleSettings> {
  const rows = await prisma.$queryRaw<Array<{ settings: unknown }>>`
    SELECT settings FROM data.system_settings WHERE module = 'geocoding'
  `
  return mergeSettings((rows[0]?.settings ?? {}) as Partial<GeocodingModuleSettings>)
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

export async function getGeocodingSettings(): Promise<GeocodingModuleSettings> {
  await assertAdmin(['admin', 'support'])
  return readGeocodingSettings()
}

export async function getGeocodingOpsSummary(): Promise<GeocodingOpsSummary> {
  await assertAdmin(['admin', 'support'])

  const settings = await readGeocodingSettings()

  const windowRows = await prisma.$queryRaw<
    Array<{ window_kind: string; request_count: number }>
  >`
    SELECT window_kind, request_count
    FROM data.geocoding_platform_rate_windows
    WHERE provider_key = 'nominatim'
      AND (
        (window_kind = 'second' AND window_start = date_trunc('second', now()))
        OR (window_kind = 'minute' AND window_start = date_trunc('minute', now()))
      )
  `

  let second_used = 0
  let minute_used = 0
  for (const row of windowRows) {
    if (row.window_kind === 'second') second_used = Number(row.request_count)
    if (row.window_kind === 'minute') minute_used = Number(row.request_count)
  }

  const todayAgg = await prisma.$queryRaw<
    Array<{
      success: bigint | number
      cached: bigint | number
      blocked: bigint | number
      provider_error: bigint | number
      network_error: bigint | number
    }>
  >`
    SELECT
      COUNT(*) FILTER (WHERE request_status = 'success') AS success,
      COUNT(*) FILTER (WHERE request_status = 'cached') AS cached,
      COUNT(*) FILTER (WHERE request_status LIKE 'blocked_%') AS blocked,
      COUNT(*) FILTER (WHERE request_status = 'provider_error') AS provider_error,
      COUNT(*) FILTER (WHERE request_status = 'network_error') AS network_error
    FROM data.geocoding_usage_ledger
    WHERE provider_key = 'nominatim'
      AND created_at >= CURRENT_DATE::timestamptz
  `

  const upstreamRows = await prisma.$queryRaw<Array<{ n: bigint | number }>>`
    SELECT COUNT(*)::bigint AS n
    FROM data.geocoding_usage_ledger
    WHERE provider_key = 'nominatim'
      AND created_at >= CURRENT_DATE::timestamptz
      AND request_status = 'provider_error'
      AND (
        (payload ->> 'status') = '429'
        OR (payload ->> 'provider_error') ILIKE '%rate limited%'
      )
  `

  const alertRows = await prisma.$queryRaw<
    Array<{
      id: string
      tenant_id: string | null
      tenant_name: string | null
      provider_key: string | null
      usage_date: Date | string
      blocked_requests: number
      threshold: number
      reason: string | null
      created_at: Date | string
    }>
  >`
    SELECT
      a.id,
      a.tenant_id,
      t.name AS tenant_name,
      a.provider_key,
      a.usage_date,
      a.blocked_requests,
      a.threshold,
      COALESCE(a.payload ->> 'reason', NULL) AS reason,
      a.created_at
    FROM data.geocoding_abuse_alerts a
    LEFT JOIN data.tenants t ON t.id = a.tenant_id
    WHERE a.usage_date >= (CURRENT_DATE - INTERVAL '30 days')
    ORDER BY a.created_at DESC
    LIMIT 50
  `

  const agg = todayAgg[0]
  return {
    settings,
    second_used,
    minute_used,
    today: {
      success: Number(agg?.success ?? 0),
      cached: Number(agg?.cached ?? 0),
      blocked: Number(agg?.blocked ?? 0),
      provider_error: Number(agg?.provider_error ?? 0),
      network_error: Number(agg?.network_error ?? 0),
    },
    upstream_429_today: Number(upstreamRows[0]?.n ?? 0),
    alerts: alertRows.map((a) => ({
      id: a.id,
      tenant_id: a.tenant_id,
      tenant_name: a.tenant_name,
      provider_key: a.provider_key,
      usage_date: typeof a.usage_date === 'string' ? a.usage_date : a.usage_date.toISOString().slice(0, 10),
      blocked_requests: Number(a.blocked_requests),
      threshold: Number(a.threshold),
      reason: a.reason,
      created_at:
        typeof a.created_at === 'string' ? a.created_at : a.created_at.toISOString(),
    })),
  }
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

export async function updateGeocodingSettings(
  settings: GeocodingModuleSettings,
): Promise<void> {
  const { user } = await assertAdmin(['admin'])

  const next: GeocodingModuleSettings = {
    nominatim_enabled: Boolean(settings.nominatim_enabled),
    nominatim_global_max_per_second: Math.max(1, Math.min(10, Math.floor(settings.nominatim_global_max_per_second))),
    nominatim_global_max_per_minute: Math.max(1, Math.min(120, Math.floor(settings.nominatim_global_max_per_minute))),
  }

  await prisma.$executeRaw`
    INSERT INTO data.system_settings (module, settings, updated_by)
    VALUES ('geocoding', ${JSON.stringify(next)}::jsonb, ${user.id}::uuid)
    ON CONFLICT (module) DO UPDATE SET
      settings   = EXCLUDED.settings,
      updated_at = now(),
      updated_by = EXCLUDED.updated_by
  `

  revalidatePath('/dashboard/settings/geocoding')
}
