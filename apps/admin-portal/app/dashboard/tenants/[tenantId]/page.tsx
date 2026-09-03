import { notFound } from 'next/navigation'
import Link from 'next/link'
import { prisma } from '@/lib/prisma'
import { createSupabaseAdminClient } from '@/lib/supabase/admin'
import { UsageGauge } from '@/components/dashboard/UsageGauge'
import { DriveSlotCard } from '@/components/dashboard/DriveSlotCard'
import { TenantLimitsForm } from '@/components/dashboard/TenantLimitsForm'
import { MembersTab } from '@/components/dashboard/MembersTab'
import { SitesTab } from '@/components/dashboard/SitesTab'
import { AuditLogsTab } from '@/components/dashboard/AuditLogsTab'
import { TenantSigningTab } from '@/components/dashboard/TenantSigningTab'
import { TenantPortalsTab } from '@/components/dashboard/TenantPortalsTab'
import { TenantCustomerClientsTab } from '@/components/dashboard/TenantCustomerClientsTab'
import { TenantAiTab } from '@/components/dashboard/TenantAiTab'
import { TenantSecretsTab } from '@/components/dashboard/TenantSecretsTab'
import { TenantMapsTab } from '@/components/dashboard/TenantMapsTab'
import { TenantFeatureFlagsTab } from '@/components/dashboard/TenantFeatureFlagsTab'
import type { MemberRow, TenantHealth } from '@/app/admin/actions/members'
import { getSitesForTenant } from '@/app/admin/actions/sites'
import { getAuditLogs } from '@/app/admin/actions/tenants'
import { getTenantGeocodingData } from '@/app/admin/actions/control-plane'
import { getTenantAiSummary } from '@/app/admin/actions/ai-settings'
import { getTenantSecretsMeta } from '@/app/admin/actions/security-secrets'
import { getPortalEntitlements } from '@/app/admin/actions/portal-entitlements'
import { listCustomerGrantsForTenant } from '@/app/admin/actions/customer-identities'
import {
  getActiveTenantMapsJsByokKeys,
  getTenantMapsJsPlatformEntitlements,
} from '@/app/admin/actions/maps-js-platform-entitlements'
import { getMapsJsClientErrorsSummary } from '@/app/admin/actions/maps-js-client-errors'
import { isTenantFeatureEffectivelyOn } from '@/lib/featureFlags'
import { getT } from '@/lib/i18n/server'

interface Props {
  params:       Promise<{ tenantId: string }>
  searchParams: Promise<{ tab?: string }>
}

function formatBytes(bytes: bigint | number): string {
  const n = Number(bytes)
  if (n < 1024) return `${n} B`
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`
  return `${(n / 1024 ** 3).toFixed(2)} GB`
}

export default async function TenantDetailPage({ params, searchParams }: Props) {
  const { tenantId }        = await params
  const { tab = 'general' } = await searchParams

  const t = getT('tenants')

  const supabaseAdmin = createSupabaseAdminClient()

  const [tenant, flags, monthlyEgress, bucketsResult, sites, emailConfigRows] = await Promise.all([
    prisma.tenants.findUnique({
      where: { id: tenantId },
      include: {
        plans: true,
        storage_usage: true,
        storage_providers: {
          where: { is_active: true },
          orderBy: { created_at: 'asc' },
        },
        tenant_storage_limits: true,
        tenant_feature_overrides: true,
        tenant_members: {
          include: {
            profiles_tenant_members_user_idToprofiles: true,
          },
          orderBy: { joined_at: 'asc' },
        },
      },
    }),

    prisma.feature_flags.findMany({
      orderBy: { key: 'asc' },
    }),

    // Monthly egress for this tenant
    prisma.storage_egress_logs.aggregate({
      where: {
        tenant_id: tenantId,
        created_at: { gte: new Date(new Date().getFullYear(), new Date().getMonth(), 1) },
      },
      _sum: { size_bytes: true },
    }),

    // Bucket info (tenant-files)
    supabaseAdmin.storage.listBuckets(),
    // Sites
    getSitesForTenant(tenantId),

    // Email domains config
    prisma.$queryRaw<Array<{ custom_domains_enabled: boolean; max_custom_domains: number }>>`
      SELECT custom_domains_enabled, max_custom_domains
      FROM data.email_configs
      WHERE tenant_id = ${tenantId}::uuid
      LIMIT 1
    `,
  ])

  const geocodingData = await getTenantGeocodingData(tenantId)

  // Audit logs: només si estem a la pestanya d'activitat
  const auditLogs = tab === 'activitat' ? await getAuditLogs(tenantId) : []

  const mapsEntitlements =
    tab === 'mapes' ? await getTenantMapsJsPlatformEntitlements(tenantId) : []
  const mapsByok =
    tab === 'mapes' ? await getActiveTenantMapsJsByokKeys(tenantId) : []
  const mapsClientErrors =
    tab === 'mapes' ? await getMapsJsClientErrorsSummary(100, tenantId) : []

  // Signing config: només si estem a la pestanya de firmes
  const signingConfigRows = tab === 'firmes'
    ? await prisma.$queryRaw<Array<{
        mode: string
        is_active: boolean
        admin_disabled: boolean
        signing_credits: number
        docuseal_api_url: string
      }>>`
        SELECT mode, is_active, admin_disabled, signing_credits, COALESCE(docuseal_api_url, '') AS docuseal_api_url
        FROM data.tenant_signing_config
        WHERE tenant_id = ${tenantId}::uuid
        LIMIT 1
      `
    : []
  const signingConfig = (signingConfigRows[0] ?? null) as {
    mode: string; is_active: boolean; admin_disabled: boolean; signing_credits: number; docuseal_api_url: string
  } | null

  const aiSummary = tab === 'ia' ? await getTenantAiSummary(tenantId) : null
  const tenantSecrets = tab === 'secrets' ? await getTenantSecretsMeta(tenantId) : []

  const portalEntitlementsRows = tab === 'portals'
    ? await prisma.$queryRaw<Array<{
        employee_portal_enabled: boolean
        tenant_portal_entitlements: Record<string, unknown> | null
      }>>`
        SELECT employee_portal_enabled, tenant_portal_entitlements
        FROM data.tenants
        WHERE id = ${tenantId}::uuid
        LIMIT 1
      `
    : []
  const portalEntitlements = tab === 'portals'
    ? await getPortalEntitlements(tenantId)
    : null

  const customerGrants =
    tab === 'clients' ? await listCustomerGrantsForTenant(tenantId) : []

  const signingFlag = (flags as Array<{ key: string; is_enabled: boolean; rollout_percentage: number }>)
    .find((f) => f.key === 'tenant_signing_enabled') ?? null
  const signingOverride = ((tenant?.tenant_feature_overrides ?? []) as Array<{ feature_key: string; override_status: boolean }>)
    .find((o) => o.feature_key === 'tenant_signing_enabled') ?? null

  const featureFlagRows = (flags as Array<{
    key: string
    description: string | null
    is_enabled: boolean
    rollout_percentage: number
  }>)
  const featureOverrideRows = ((tenant?.tenant_feature_overrides ?? []) as Array<{
    feature_key: string
    override_status: boolean
  }>)
  const featureOverrideMap = new Map(
    featureOverrideRows.map((o) => [o.feature_key, o.override_status]),
  )
  const featureFlagsActiveCount = featureFlagRows.filter((f) =>
    isTenantFeatureEffectivelyOn(f, featureOverrideMap.get(f.key)),
  ).length

  const emailDomainsCfg = emailConfigRows[0] ?? null

  const planLimitRows = await prisma.$queryRaw<Array<{ max_sites: number | null }>>`
    SELECT p.max_sites
    FROM data.tenants t
    LEFT JOIN data.plans p ON p.id = t.plan_id
    WHERE t.id = ${tenantId}::uuid
    LIMIT 1
  `

  const membershipRows = await prisma.$queryRaw<Array<{
    id: string
    user_id: string
    email: string
    full_name: string | null
    role: string
    is_active: boolean
    joined_at: Date
    first_login_at: Date | null
    last_login_at: Date | null
    site_id: string | null
    site_name: string | null
  }>>`
    SELECT
      tm.id,
      tm.user_id,
      p.email,
      p.full_name,
      tm.role,
      tm.is_active,
      tm.joined_at,
      p.first_login_at,
      p.last_login_at,
      tm.site_id,
      s.name AS site_name
    FROM data.tenant_members tm
    INNER JOIN data.profiles p ON p.id = tm.user_id
    LEFT JOIN data.sites s ON s.id = tm.site_id
    WHERE tm.tenant_id = ${tenantId}::uuid
    ORDER BY p.email ASC, tm.site_id NULLS FIRST, tm.joined_at ASC
  `

  const inviteTenantRows = await prisma.$queryRaw<Array<{ id: string; name: string }>>`
    SELECT id, name
    FROM data.tenants
    WHERE is_active = true
    ORDER BY name ASC
  `

  if (!tenant) notFound()

  const usedBytes =
    (tenant.storage_usage?.committed_bytes ?? BigInt(0)) +
    (tenant.storage_usage?.reserved_bytes ?? BigInt(0)) +
    (tenant.storage_usage?.documents_committed_bytes ?? BigInt(0)) +
    (tenant.storage_usage?.documents_reserved_bytes ?? BigInt(0))

  const planQuotaBytes = BigInt((tenant.plans?.max_storage_mb ?? 0) * 1024 * 1024)

  const effectiveQuotaBytes = tenant.tenant_storage_limits?.internal_quota_gb
    ? BigInt(
        Math.round(Number(tenant.tenant_storage_limits.internal_quota_gb) * 1024 * 1024 * 1024)
      )
    : planQuotaBytes

  const egressBytes = monthlyEgress._sum.size_bytes ?? BigInt(0)

  // BYOS drives (exclude internal supabase row, take up to 3 BYOS slots)
  const byosDrives = (tenant.storage_providers as Array<{
    id: string; nickname: string | null; provider_type: string;
    bucket_name: string | null; is_active: boolean; is_locked: boolean; is_verified: boolean;
  }>).filter((p) => p.provider_type !== 'supabase')

  const limitsData = tenant.tenant_storage_limits
    ? {
        internal_quota_gb: tenant.tenant_storage_limits.internal_quota_gb
          ? Number(tenant.tenant_storage_limits.internal_quota_gb)
          : null,
        internal_max_file_mb: tenant.tenant_storage_limits.internal_max_file_mb,
        internal_allowed_mimes: tenant.tenant_storage_limits.internal_allowed_mimes,
      }
    : null

  // Bucket limits (tenant-files)
  const tenantFileBucket = (bucketsResult.data ?? []).find((b) => b.name === 'tenant-files') ?? null
  const bucketFileSizeLimitBytes = tenantFileBucket?.file_size_limit ?? null
  const bucketAllowedMimes = tenantFileBucket?.allowed_mime_types ?? null

  const maxSites = Number(planLimitRows[0]?.max_sites ?? 0)

  // ---------------------------------------------------------------------------
  // Members — build MemberRow[] (serialisable for client component)
  // ---------------------------------------------------------------------------
  const activeOwnerCount = membershipRows.filter(
    (m) => m.is_active && m.role === 'owner' && m.site_id === null,
  ).length

  const memberRows: MemberRow[] = membershipRows.map((m) => ({
    id:           m.id,
    userId:       m.user_id,
    email:        m.email,
    fullName:     m.full_name,
    role:         m.role,
    scope:        m.site_id ? 'site' : 'global',
    siteId:       m.site_id,
    siteName:     m.site_name,
    isActive:     m.is_active,
    joinedAt:     m.joined_at.toISOString(),
    isPending:    m.first_login_at === null,
    firstLoginAt: m.first_login_at ? m.first_login_at.toISOString() : null,
    lastLoginAt:  m.last_login_at  ? m.last_login_at.toISOString()  : null,
    // Last owner protection only applies to global owner memberships.
    isLastOwner:  m.site_id === null && m.role === 'owner' && m.is_active && activeOwnerCount === 1,
  }))

  // Health summary (equivalent to data.check_tenant_health())
  const activeMembers  = new Set(membershipRows.filter((m) => m.is_active).map((m) => m.user_id)).size
  const hasActiveOwner = activeOwnerCount > 0
  const maxUsers       = tenant.plans?.max_members ?? 0
  const isOverQuota    = maxUsers > 0 && activeMembers > maxUsers

  const inviteTenants = inviteTenantRows.map((t) => ({ tenantId: t.id, name: t.name }))

  const health: TenantHealth = {
    has_active_owner: hasActiveOwner,
    active_members:   activeMembers,
    max_users:        maxUsers,
    is_over_quota:    isOverQuota,
  }

  return (
    <div className="space-y-8">
      {/* Header */}
      <div className="flex items-center gap-3">
        <Link
          href="/dashboard/tenants"
          className="text-sm text-gray-400 hover:text-indigo-600 transition"
        >
          {t('tenants.detail.back', '← Enrere')}
        </Link>
        <span className="text-gray-200">/</span>
        <h1 className="text-2xl font-bold text-gray-900">{tenant.name}</h1>
        {tenant.storage_blocked && (
          <span className="px-2 py-0.5 bg-red-50 text-red-700 text-xs font-semibold rounded-full">
            {t('tenants.detail.storage_blocked', 'Emmagatzematge bloquejat')}
          </span>
        )}
        {!tenant.is_active && (
          <span className="px-2 py-0.5 bg-gray-100 text-gray-500 text-xs font-semibold rounded-full">
            {t('tenants.detail.archived', 'Arxivat')}
          </span>
        )}
        {!hasActiveOwner && (
          <span className="px-2 py-0.5 bg-amber-50 text-amber-700 border border-amber-200 text-xs font-semibold rounded-full">
            {t('tenants.detail.no_owner_warning', '\u26a0 Atenci\u00f3: Aquest tenant no t\u00e9 cap administrador actiu')}
          </span>
        )}
        {isOverQuota && (
          <span className="px-2 py-0.5 bg-red-50 text-red-700 border border-red-200 text-xs font-semibold rounded-full">
            {t('tenants.detail.over_quota_warning', "\u26a0 Quota d'usuaris superada")}
          </span>
        )}
      </div>

      {/* Meta info */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
        <InfoCard label={t('tenants.detail.slug', 'Slug')}   value={tenant.slug} />
        <InfoCard label={t('tenants.detail.plan', 'Pla')}    value={tenant.plans?.display_name ?? '\u2014'} />
        <InfoCard
          label={t('tenants.detail.active_users', 'Usuaris actius')}
          value={maxUsers > 0 ? `${activeMembers} / ${maxUsers}` : String(activeMembers)}
          highlight={isOverQuota ? 'danger' : !hasActiveOwner ? 'warning' : undefined}
        />
        <InfoCard label={t('tenants.detail.created', 'Creat')}  value={new Date(tenant.created_at).toLocaleDateString('ca-ES')} />
      </div>

      {/* Tab navigation */}
      <div className="flex gap-0 border-b border-gray-100">
        <Link
          href={`/dashboard/tenants/${tenantId}`}
          className={`px-5 py-2.5 text-sm font-medium border-b-2 transition ${
            tab === 'general'
              ? 'text-indigo-600 border-indigo-600'
              : 'text-gray-500 border-transparent hover:text-gray-700 hover:border-gray-300'
          }`}
        >
          {t('tenants.detail.tabs.general', 'General')}
        </Link>
        <Link
          href={`/dashboard/tenants/${tenantId}?tab=membres`}
          className={`px-5 py-2.5 text-sm font-medium border-b-2 transition flex items-center gap-2 ${
            tab === 'membres'
              ? 'text-indigo-600 border-indigo-600'
              : 'text-gray-500 border-transparent hover:text-gray-700 hover:border-gray-300'
          }`}
        >
          {t('tenants.detail.tabs.members', 'Membres')}
          <span className="text-xs bg-gray-100 text-gray-600 rounded-full px-2 py-0.5 font-normal">
            {activeMembers}
          </span>
        </Link>
        <Link
          href={`/dashboard/tenants/${tenantId}?tab=clients`}
          className={`px-5 py-2.5 text-sm font-medium border-b-2 transition ${
            tab === 'clients'
              ? 'text-indigo-600 border-indigo-600'
              : 'text-gray-500 border-transparent hover:text-gray-700 hover:border-gray-300'
          }`}
        >
          {t('tenants.detail.tabs.clients', 'Clients portal')}
        </Link>
        <Link
          href={`/dashboard/tenants/${tenantId}?tab=sites`}
          className={`px-5 py-2.5 text-sm font-medium border-b-2 transition flex items-center gap-2 ${
            tab === 'sites'
              ? 'text-indigo-600 border-indigo-600'
              : 'text-gray-500 border-transparent hover:text-gray-700 hover:border-gray-300'
          }`}
        >
          {t('tenants.detail.tabs.sites', 'Sites / Locals')}
          <span className="text-xs bg-gray-100 text-gray-600 rounded-full px-2 py-0.5 font-normal">
            {sites.filter((s) => s.is_active).length}
          </span>
        </Link>
        <Link
          href={`/dashboard/tenants/${tenantId}?tab=activitat`}
          className={`px-5 py-2.5 text-sm font-medium border-b-2 transition ${
            tab === 'activitat'
              ? 'text-indigo-600 border-indigo-600'
              : 'text-gray-500 border-transparent hover:text-gray-700 hover:border-gray-300'
          }`}
        >
          {t('tenants.detail.tabs.activity', 'Activitat / Logs')}
        </Link>
        <Link
          href={`/dashboard/tenants/${tenantId}?tab=features`}
          className={`px-5 py-2.5 text-sm font-medium border-b-2 transition flex items-center gap-2 ${
            tab === 'features'
              ? 'text-indigo-600 border-indigo-600'
              : 'text-gray-500 border-transparent hover:text-gray-700 hover:border-gray-300'
          }`}
        >
          {t('tenants.detail.tabs.features', 'Feature Flags')}
          <span className="text-xs bg-gray-100 text-gray-600 rounded-full px-2 py-0.5 font-normal">
            {featureFlagsActiveCount}/{featureFlagRows.length}
          </span>
        </Link>
        <Link
          href={`/dashboard/tenants/${tenantId}?tab=firmes`}
          className={`px-5 py-2.5 text-sm font-medium border-b-2 transition ${
            tab === 'firmes'
              ? 'text-indigo-600 border-indigo-600'
              : 'text-gray-500 border-transparent hover:text-gray-700 hover:border-gray-300'
          }`}
        >
          {t('tenants.detail.tabs.firmes', 'Firmes')}
        </Link>
        <Link
          href={`/dashboard/tenants/${tenantId}?tab=ia`}
          className={`px-5 py-2.5 text-sm font-medium border-b-2 transition ${
            tab === 'ia'
              ? 'text-indigo-600 border-indigo-600'
              : 'text-gray-500 border-transparent hover:text-gray-700 hover:border-gray-300'
          }`}
        >
          {t('tenants.detail.tabs.ai', 'IA')}
        </Link>
        <Link
          href={`/dashboard/tenants/${tenantId}?tab=mapes`}
          className={`px-5 py-2.5 text-sm font-medium border-b-2 transition ${
            tab === 'mapes'
              ? 'text-indigo-600 border-indigo-600'
              : 'text-gray-500 border-transparent hover:text-gray-700 hover:border-gray-300'
          }`}
        >
          {t('tenants.detail.tabs.maps', 'Mapes')}
        </Link>
        <Link
          href={`/dashboard/tenants/${tenantId}?tab=portals`}
          className={`px-5 py-2.5 text-sm font-medium border-b-2 transition ${
            tab === 'portals'
              ? 'text-indigo-600 border-indigo-600'
              : 'text-gray-500 border-transparent hover:text-gray-700 hover:border-gray-300'
          }`}
        >
          Portals
        </Link>
        <Link
          href={`/dashboard/tenants/${tenantId}?tab=secrets`}
          className={`px-5 py-2.5 text-sm font-medium border-b-2 transition ${
            tab === 'secrets'
              ? 'text-indigo-600 border-indigo-600'
              : 'text-gray-500 border-transparent hover:text-gray-700 hover:border-gray-300'
          }`}
        >
          Secrets
        </Link>
      </div>

      {/* General tab */}
      {tab === 'general' && (
        <>
          {/* Usage gauges */}
          <div className="bg-white rounded-2xl border border-gray-100 p-6 space-y-5 shadow-sm">
            <h2 className="text-sm font-semibold text-gray-700">Ús d&apos;emmagatzematge</h2>

            <UsageGauge
              label={t('tenants.detail.internal_quota_label', 'Quota del bucket intern')}
              usedBytes={usedBytes}
              quotaBytes={effectiveQuotaBytes}
              formatValue={formatBytes}
            />

            <UsageGauge
              label={t('tenants.detail.monthly_egress_label', 'Egress mensual (mes actual)')}
              usedBytes={egressBytes}
              quotaBytes={0}
              formatValue={formatBytes}
            />
          </div>

          {/* Drive slots */}
          <div className="bg-white rounded-2xl border border-gray-100 p-6 space-y-4 shadow-sm">
            <h2 className="text-sm font-semibold text-gray-700">{t('tenants.detail.drives_title', "Unitats d'emmagatzematge")}</h2>
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
              <DriveSlotCard index={0} />
              {[0, 1, 2].map((i) => (
                <DriveSlotCard key={i + 1} index={i + 1} drive={byosDrives[i] ?? null} />
              ))}
            </div>
          </div>

          {/* Management form */}
          <TenantLimitsForm
            tenantId={tenant.id}
            storageBlocked={tenant.storage_blocked}
            storageBlockedReason={tenant.storage_blocked_reason}
            limits={limitsData}
            bucketFileSizeLimitBytes={bucketFileSizeLimitBytes}
            bucketAllowedMimes={bucketAllowedMimes}
            emailDomainsEnabled={emailDomainsCfg?.custom_domains_enabled ?? false}
            maxEmailDomains={emailDomainsCfg?.max_custom_domains ?? 1}
            geocodingData={geocodingData}
            sections="storage"
          />
        </>
      )}

      {tab === 'mapes' && (
        <TenantMapsTab
          tenantId={tenantId}
          geocodingData={geocodingData}
          entitlement={mapsEntitlements[0] ?? null}
          byokActiveSince={mapsByok[0]?.active_since ?? null}
          clientErrors={mapsClientErrors}
        />
      )}

      {tab === 'features' && (
        <TenantFeatureFlagsTab
          tenantId={tenantId}
          flags={featureFlagRows}
          overrides={featureOverrideRows}
        />
      )}

      {/* Membres tab */}
      {tab === 'membres' && (
        <MembersTab
          tenantId={tenantId}
          health={health}
          members={memberRows}
          inviteTenants={inviteTenants}
        />
      )}

      {tab === 'clients' && (
        <TenantCustomerClientsTab tenantId={tenantId} grants={customerGrants} />
      )}

      {/* Sites tab */}
      {tab === 'sites' && (
        <SitesTab
          tenantId={tenantId}
          maxSites={maxSites}
          sites={sites}
        />
      )}

      {/* Activitat / Logs tab */}
      {tab === 'activitat' && (
        <AuditLogsTab logs={auditLogs} />
      )}

      {/* Firmes tab */}
      {tab === 'firmes' && (
        <TenantSigningTab
          tenantId={tenantId}
          flagIsEnabled={signingFlag?.is_enabled ?? false}
          flagRolloutPct={signingFlag?.rollout_percentage ?? 0}
          override={signingOverride !== null ? signingOverride.override_status : null}
          signingConfig={signingConfig}
        />
      )}

      {tab === 'ia' && aiSummary && (
        <TenantAiTab summary={aiSummary} />
      )}

      {tab === 'portals' && portalEntitlements && (
        <TenantPortalsTab
          tenantId={tenantId}
          planName={tenant.plans?.display_name ?? '—'}
          initial={portalEntitlements}
          employeePortalEnabled={portalEntitlementsRows[0]?.employee_portal_enabled ?? false}
          publicPortalEnabled={tenant.public_portal_enabled}
          snapshot={(portalEntitlementsRows[0]?.tenant_portal_entitlements ?? portalEntitlements.tenant_portal_entitlements ?? {}) as import('@/app/admin/actions/portal-entitlements').TenantPortalEntitlementsSnapshot}
        />
      )}

      {tab === 'secrets' && (
        <TenantSecretsTab tenantId={tenantId} secrets={tenantSecrets} />
      )}
    </div>
  )
}

function InfoCard({
  label,
  value,
  highlight,
}: {
  label: string
  value: string
  highlight?: 'warning' | 'danger'
}) {
  return (
    <div className={`rounded-xl p-4 ${
      highlight === 'danger'  ? 'bg-red-50'    :
      highlight === 'warning' ? 'bg-amber-50'  :
      'bg-gray-50'
    }`}>
      <p className="text-xs text-gray-400 mb-0.5">{label}</p>
      <p className={`text-sm font-semibold truncate ${
        highlight === 'danger'  ? 'text-red-700'   :
        highlight === 'warning' ? 'text-amber-700' :
        'text-gray-800'
      }`}>{value}</p>
    </div>
  )
}
