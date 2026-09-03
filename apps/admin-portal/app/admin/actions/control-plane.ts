'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

// ---------------------------------------------------------------------------
// Typed shapes for each settings module
// ---------------------------------------------------------------------------
export interface AuthSettings {
  google_oauth_enabled: boolean
  password_login_enabled: boolean
  magic_link_enabled: boolean
}

export interface OnboardingSettings {
  self_signup_enabled: boolean
}

const AUTH_DEFAULTS: AuthSettings = {
  google_oauth_enabled: true,
  password_login_enabled: true,
  magic_link_enabled: false,
}

const ONBOARDING_DEFAULTS: OnboardingSettings = {
  self_signup_enabled: false,
}

// ---------------------------------------------------------------------------
// Auth guard (same pattern as tenants.ts)
// ---------------------------------------------------------------------------
async function assertAdmin(allowedRoles: ('admin' | 'support')[] = ['admin', 'support']) {
  const supabase = await createSupabaseServerClient()
  const { data: { user }, error } = await supabase.auth.getUser()
  if (error || !user) throw new Error('Unauthenticated')
  const role = user.app_metadata?.role as string | undefined
  if (!role || !allowedRoles.includes(role as 'admin' | 'support')) {
    throw new Error(`Forbidden: requires one of [${allowedRoles.join(', ')}]`)
  }
  return { user, role }
}

// ---------------------------------------------------------------------------
// setStorageBlock — block or unblock a tenant's storage
// ---------------------------------------------------------------------------
export async function setStorageBlock(
  tenantId: string,
  blocked: boolean,
  reason?: string
) {
  await assertAdmin(['admin'])

  await prisma.tenants.update({
    where: { id: tenantId },
    data: {
      storage_blocked: blocked,
      storage_blocked_reason: blocked ? (reason ?? 'Bloquejat per l\'administrador') : null,
      storage_blocked_at: blocked ? new Date() : null,
    },
  })

  revalidatePath('/dashboard')
  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ---------------------------------------------------------------------------
// upsertTenantStorageLimits — set per-tenant internal bucket limits
// ---------------------------------------------------------------------------
export async function upsertTenantStorageLimits(
  tenantId: string,
  data: {
    internal_quota_gb?: number | null
    internal_max_file_mb?: number | null
    internal_allowed_mimes?: string[]
  }
) {
  await assertAdmin(['admin'])

  await prisma.tenant_storage_limits.upsert({
    where: { tenant_id: tenantId },
    update: {
      internal_quota_gb: data.internal_quota_gb !== undefined
        ? (data.internal_quota_gb === null ? null : data.internal_quota_gb)
        : undefined,
      internal_max_file_mb: data.internal_max_file_mb !== undefined
        ? data.internal_max_file_mb
        : undefined,
      internal_allowed_mimes: data.internal_allowed_mimes ?? [],
      updated_at: new Date(),
    },
    create: {
      tenant_id: tenantId,
      internal_quota_gb: data.internal_quota_gb ?? null,
      internal_max_file_mb: data.internal_max_file_mb ?? null,
      internal_allowed_mimes: data.internal_allowed_mimes ?? [],
    },
  })

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ---------------------------------------------------------------------------
// upsertFeatureOverride — set a per-tenant feature flag override
// ---------------------------------------------------------------------------
export async function upsertFeatureOverride(
  tenantId: string,
  featureKey: string,
  overrideStatus: boolean
) {
  await assertAdmin(['admin'])

  await prisma.tenant_feature_overrides.upsert({
    where: { tenant_id_feature_key: { tenant_id: tenantId, feature_key: featureKey } },
    update: { override_status: overrideStatus, updated_at: new Date() },
    create: { tenant_id: tenantId, feature_key: featureKey, override_status: overrideStatus },
  })

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ---------------------------------------------------------------------------
// deleteFeatureOverride — remove feature flag override (reverts to global default)
// ---------------------------------------------------------------------------
export async function deleteFeatureOverride(tenantId: string, featureKey: string) {
  await assertAdmin(['admin'])

  await prisma.tenant_feature_overrides.delete({
    where: { tenant_id_feature_key: { tenant_id: tenantId, feature_key: featureKey } },
  }).catch(() => {
    // Ignore if override didn't exist
  })

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ---------------------------------------------------------------------------
// upsertFeatureFlag — create or update a global feature flag
// ---------------------------------------------------------------------------
export async function upsertFeatureFlag(data: {
  key: string
  description?: string
  is_enabled: boolean
  rollout_percentage: number
}) {
  await assertAdmin(['admin'])

  await prisma.feature_flags.upsert({
    where: { key: data.key },
    update: {
      description: data.description,
      is_enabled: data.is_enabled,
      rollout_percentage: data.rollout_percentage,
      updated_at: new Date(),
    },
    create: {
      key: data.key,
      description: data.description,
      is_enabled: data.is_enabled,
      rollout_percentage: data.rollout_percentage,
    },
  })

  revalidatePath('/dashboard')
  revalidatePath('/dashboard/settings/feature-flags')
  revalidatePath('/dashboard/settings/signing')
  revalidatePath('/dashboard/tenants', 'layout')
}

// ---------------------------------------------------------------------------
// getAuthSettings — read the 'auth' module, merging defaults for missing keys
// ---------------------------------------------------------------------------
export async function getAuthSettings(): Promise<AuthSettings> {
  const rows = await prisma.$queryRaw<Array<{ settings: unknown }>>`
    SELECT settings FROM data.system_settings WHERE module = 'auth'
  `
  const raw = (rows[0]?.settings ?? {}) as Partial<AuthSettings>
  return { ...AUTH_DEFAULTS, ...raw }
}

// ---------------------------------------------------------------------------
// updateAuthSettings — full replace of the auth module settings
// ---------------------------------------------------------------------------
export async function updateAuthSettings(settings: AuthSettings) {
  const { user } = await assertAdmin(['admin'])

  await prisma.$executeRaw`
    INSERT INTO data.system_settings (module, settings, updated_by)
    VALUES ('auth', ${JSON.stringify(settings)}::jsonb, ${user.id}::uuid)
    ON CONFLICT (module) DO UPDATE SET
      settings   = EXCLUDED.settings,
      updated_at = now(),
      updated_by = EXCLUDED.updated_by
  `

  revalidatePath('/dashboard/settings')
}

// ---------------------------------------------------------------------------
// getOnboardingSettings — read the 'onboarding' module
// ---------------------------------------------------------------------------
export async function getOnboardingSettings(): Promise<OnboardingSettings> {
  const rows = await prisma.$queryRaw<Array<{ settings: unknown }>>`
    SELECT settings FROM data.system_settings WHERE module = 'onboarding'
  `
  const raw = (rows[0]?.settings ?? {}) as Partial<OnboardingSettings>
  return { ...ONBOARDING_DEFAULTS, ...raw }
}

// ---------------------------------------------------------------------------
// updateOnboardingSettings — full replace of the onboarding module settings
// ---------------------------------------------------------------------------
export async function updateOnboardingSettings(settings: OnboardingSettings) {
  const { user } = await assertAdmin(['admin'])

  await prisma.$executeRaw`
    INSERT INTO data.system_settings (module, settings, updated_by)
    VALUES ('onboarding', ${JSON.stringify(settings)}::jsonb, ${user.id}::uuid)
    ON CONFLICT (module) DO UPDATE SET
      settings   = EXCLUDED.settings,
      updated_at = now(),
      updated_by = EXCLUDED.updated_by
  `

  revalidatePath('/dashboard/settings')
}

// ---------------------------------------------------------------------------
// upsertEmailDomainsConfig — habilitar/deshabilitar dominis personalitzats i quota
// ---------------------------------------------------------------------------
export async function upsertEmailDomainsConfig(
  tenantId: string,
  data: {
    custom_domains_enabled: boolean
    max_custom_domains: number
  }
) {
  await assertAdmin(['admin'])

  await prisma.$executeRaw`
    INSERT INTO data.email_configs (tenant_id, custom_domains_enabled, max_custom_domains)
    VALUES (
      ${tenantId}::uuid,
      ${data.custom_domains_enabled},
      ${data.max_custom_domains}
    )
    ON CONFLICT (tenant_id) DO UPDATE SET
      custom_domains_enabled = EXCLUDED.custom_domains_enabled,
      max_custom_domains     = EXCLUDED.max_custom_domains,
      updated_at             = now()
  `

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ===========================================================================
// GEOCODING CONTROL PLANE
// ===========================================================================

// ---------------------------------------------------------------------------
// Typed shapes
// ---------------------------------------------------------------------------
export interface GeocodingProvider {
  provider_key: string
  name: string
  is_active: boolean
}

export interface TenantGeocodingProviderConfig {
  tenant_id: string
  provider_key: string
  mode: 'platform' | 'byo'
  is_enabled: boolean
  priority: number
  api_key_secret_id: string | null
  has_api_key: boolean
}

export interface TenantGeocodingLimitOverride {
  tenant_id: string
  provider_key: string
  included_total_requests_month: number | null
  included_search_requests_month: number | null
  included_reverse_requests_month: number | null
  rate_limit_per_minute: number | null
  rate_limit_per_day: number | null
  enforce_hard_cap: boolean | null
  allow_overage: boolean | null
  billable: boolean | null
  overage_price_per_1000: string | null
  currency: string | null
}

export interface TenantGeocodingMonthlyUsage {
  provider_key: string
  usage_month: Date
  total_requests: number
  search_requests: number
  reverse_requests: number
  successful_requests: number
  blocked_requests: number
  billable_units: number
  cost_amount: string
}

export interface TenantGeocodingEffectiveLimits {
  provider_key: string
  mode: string
  is_enabled: boolean
  included_total_requests_month: number | null
  included_search_requests_month: number | null
  included_reverse_requests_month: number | null
  rate_limit_per_minute: number
  rate_limit_per_day: number
  enforce_hard_cap: boolean
  allow_overage: boolean
  billable: boolean
  overage_price_per_1000: string
  currency: string
}

export interface TenantGeocodingData {
  providers: GeocodingProvider[]
  configs: TenantGeocodingProviderConfig[]
  overrides: TenantGeocodingLimitOverride[]
  monthlyUsage: TenantGeocodingMonthlyUsage[]
  effectiveLimits: TenantGeocodingEffectiveLimits[]
}

// ---------------------------------------------------------------------------
// getGeocodingProviders — catàleg de providers actius
// ---------------------------------------------------------------------------
export async function getGeocodingProviders(): Promise<GeocodingProvider[]> {
  await assertAdmin()

  const rows = await prisma.$queryRaw<GeocodingProvider[]>`
    SELECT provider_key, name, is_active
    FROM data.geocoding_providers
    ORDER BY provider_key ASC
  `
  return rows
}

// ---------------------------------------------------------------------------
// getTenantGeocodingData — lectura combinada per a la UI de detall de tenant
// ---------------------------------------------------------------------------
export async function getTenantGeocodingData(tenantId: string): Promise<TenantGeocodingData> {
  await assertAdmin()

  // Mes actual (primer dia del mes)
  const now = new Date()
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1)

  const [providers, configs, overrides, monthlyUsage] = await Promise.all([
    prisma.$queryRaw<GeocodingProvider[]>`
      SELECT provider_key, name, is_active
      FROM data.geocoding_providers
      ORDER BY provider_key ASC
    `,
    prisma.$queryRaw<TenantGeocodingProviderConfig[]>`
      SELECT tenant_id::text, provider_key, mode, is_enabled, priority,
             api_key_secret_id, (api_key_secret_id IS NOT NULL) AS has_api_key
      FROM data.tenant_geocoding_provider_configs
      WHERE tenant_id = ${tenantId}::uuid
      ORDER BY priority ASC
    `,
    prisma.$queryRaw<TenantGeocodingLimitOverride[]>`
      SELECT
        tenant_id::text,
        provider_key,
        included_total_requests_month,
        included_search_requests_month,
        included_reverse_requests_month,
        rate_limit_per_minute,
        rate_limit_per_day,
        enforce_hard_cap,
        allow_overage,
        billable,
        overage_price_per_1000::text,
        currency
      FROM data.tenant_geocoding_limit_overrides
      WHERE tenant_id = ${tenantId}::uuid
    `,
    prisma.$queryRaw<TenantGeocodingMonthlyUsage[]>`
      SELECT
        provider_key,
        usage_month,
        total_requests,
        search_requests,
        reverse_requests,
        successful_requests,
        blocked_requests,
        billable_units::integer,
        cost_amount::text
      FROM data.geocoding_usage_monthly
      WHERE tenant_id = ${tenantId}::uuid
        AND usage_month = ${monthStart}::date
    `,
  ])

  // Límits efectius per cada provider configurat (o el primer actiu si no n'hi ha cap)
  const providerKeys =
    configs.length > 0
      ? configs.map((c) => c.provider_key)
      : providers.filter((p) => p.is_active).map((p) => p.provider_key)

  const effectiveLimits: TenantGeocodingEffectiveLimits[] = []
  for (const key of providerKeys) {
    const rows = await prisma.$queryRaw<TenantGeocodingEffectiveLimits[]>`
      SELECT
        provider_key,
        mode,
        is_enabled,
        included_total_requests_month,
        included_search_requests_month,
        included_reverse_requests_month,
        rate_limit_per_minute,
        rate_limit_per_day,
        enforce_hard_cap,
        allow_overage,
        billable,
        overage_price_per_1000::text,
        currency
      FROM data.get_effective_geocoding_limits(${tenantId}::uuid, ${key})
    `
    if (rows[0]) effectiveLimits.push(rows[0])
  }

  return { providers, configs, overrides, monthlyUsage, effectiveLimits }
}

// ---------------------------------------------------------------------------
// upsertTenantGeocodingProviderConfig — mode/is_enabled/priority per tenant+provider
// ---------------------------------------------------------------------------
export async function upsertTenantGeocodingProviderConfig(
  tenantId: string,
  data: {
    provider_key: string
    mode: 'platform' | 'byo'
    is_enabled: boolean
    priority?: number
  }
) {
  await assertAdmin(['admin'])

  const priority = data.priority ?? 100

  await prisma.$executeRaw`
    INSERT INTO data.tenant_geocoding_provider_configs
      (tenant_id, provider_key, mode, is_enabled, priority)
    VALUES
      (${tenantId}::uuid, ${data.provider_key}, ${data.mode}, ${data.is_enabled}, ${priority})
    ON CONFLICT (tenant_id, provider_key) DO UPDATE SET
      mode       = EXCLUDED.mode,
      is_enabled = EXCLUDED.is_enabled,
      priority   = EXCLUDED.priority,
      updated_at = now()
  `

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ---------------------------------------------------------------------------
// upsertTenantGeocodingLimitOverride — tots els camps d'override (nullable = hereta del pla)
// ---------------------------------------------------------------------------
export async function upsertTenantGeocodingLimitOverride(
  tenantId: string,
  data: {
    provider_key: string
    included_total_requests_month?: number | null
    included_search_requests_month?: number | null
    included_reverse_requests_month?: number | null
    rate_limit_per_minute?: number | null
    rate_limit_per_day?: number | null
    enforce_hard_cap?: boolean | null
    allow_overage?: boolean | null
    billable?: boolean | null
    overage_price_per_1000?: number | null
    currency?: string | null
  }
) {
  await assertAdmin(['admin'])

  // Validacions de rang
  const positiveOrNull = (v: number | null | undefined) => {
    if (v == null) return null
    if (v < 0) throw new Error(`El valor ha de ser positiu o null`)
    return v
  }

  const totalMonth  = positiveOrNull(data.included_total_requests_month)
  const searchMonth = positiveOrNull(data.included_search_requests_month)
  const reverseMonth = positiveOrNull(data.included_reverse_requests_month)
  const rpm = data.rate_limit_per_minute != null ? (data.rate_limit_per_minute > 0 ? data.rate_limit_per_minute : (() => { throw new Error('rate_limit_per_minute ha de ser > 0') })()) : null
  const rpd = data.rate_limit_per_day != null ? (data.rate_limit_per_day > 0 ? data.rate_limit_per_day : (() => { throw new Error('rate_limit_per_day ha de ser > 0') })()) : null
  const price = data.overage_price_per_1000 != null ? (data.overage_price_per_1000 >= 0 ? data.overage_price_per_1000 : (() => { throw new Error('overage_price_per_1000 ha de ser >= 0') })()) : null
  const currency = data.currency ?? null

  await prisma.$executeRaw`
    INSERT INTO data.tenant_geocoding_limit_overrides (
      tenant_id,
      provider_key,
      included_total_requests_month,
      included_search_requests_month,
      included_reverse_requests_month,
      rate_limit_per_minute,
      rate_limit_per_day,
      enforce_hard_cap,
      allow_overage,
      billable,
      overage_price_per_1000,
      currency
    )
    VALUES (
      ${tenantId}::uuid,
      ${data.provider_key},
      ${totalMonth},
      ${searchMonth},
      ${reverseMonth},
      ${rpm},
      ${rpd},
      ${data.enforce_hard_cap ?? null},
      ${data.allow_overage ?? null},
      ${data.billable ?? null},
      ${price},
      ${currency}
    )
    ON CONFLICT (tenant_id, provider_key) DO UPDATE SET
      included_total_requests_month   = EXCLUDED.included_total_requests_month,
      included_search_requests_month  = EXCLUDED.included_search_requests_month,
      included_reverse_requests_month = EXCLUDED.included_reverse_requests_month,
      rate_limit_per_minute           = EXCLUDED.rate_limit_per_minute,
      rate_limit_per_day              = EXCLUDED.rate_limit_per_day,
      enforce_hard_cap                = EXCLUDED.enforce_hard_cap,
      allow_overage                   = EXCLUDED.allow_overage,
      billable                        = EXCLUDED.billable,
      overage_price_per_1000          = EXCLUDED.overage_price_per_1000,
      currency                        = EXCLUDED.currency,
      updated_at                      = now()
  `

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ---------------------------------------------------------------------------
// deleteTenantGeocodingLimitOverride — elimina l'override (reverteix als valors del pla)
// ---------------------------------------------------------------------------
export async function deleteTenantGeocodingLimitOverride(
  tenantId: string,
  providerKey: string
) {
  await assertAdmin(['admin'])

  await prisma.$executeRaw`
    DELETE FROM data.tenant_geocoding_limit_overrides
    WHERE tenant_id = ${tenantId}::uuid
      AND provider_key = ${providerKey}
  `

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}
