import Link from 'next/link'
import { unstable_cache } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { KpiCard } from '@/components/dashboard/KpiCard'
import { getActivityStats } from '@/app/admin/actions/analytics'
import { NewUsersChart } from '@/components/dashboard/NewUsersChart'
import { ActivityBucketsChart } from '@/components/dashboard/ActivityBucketsChart'
import { AtRiskUsersTable } from '@/components/dashboard/AtRiskUsersTable'
import { getT } from '@/lib/i18n/server'

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`
  return `${(n / 1024 ** 3).toFixed(2)} GB`
}

// Cache platform-wide KPIs for 60 seconds to avoid hammering the DB on every page view
const getDashboardKpis = unstable_cache(
  async () => {
    const [summary, recentTenants, recentByos, geoRows] = await Promise.all([
      prisma.billing_summary.findMany(),
      prisma.tenants.findMany({
        take: 5,
        orderBy: { created_at: 'desc' },
        select: {
          id: true,
          name: true,
          created_at: true,
          plans: { select: { display_name: true } },
        },
      }),
      prisma.storage_providers.findMany({
        where: { is_verified: true },
        take: 5,
        orderBy: { updated_at: 'desc' },
        select: {
          id: true,
          nickname: true,
          provider_type: true,
          updated_at: true,
          tenants: { select: { name: true } },
        },
      }),
      prisma.$queryRaw<Array<{
        total_requests: number
        platform_cost: string
      }>>`
        SELECT
          COALESCE(SUM(total_requests), 0)::integer AS total_requests,
          COALESCE(SUM(cost_amount),    0)::text    AS platform_cost
        FROM data.geocoding_usage_monthly
        WHERE usage_month = date_trunc('month', now())::date
      `,
    ])

    const active = summary.filter((s) => s.is_active)
    const activeTenants = active.length
    const inactiveTenants = summary.length - activeTenants
    const tenantsWithOwner = active.filter((s) => s.has_active_owner).length
    const healthPct = activeTenants > 0 ? Math.round((tenantsWithOwner / activeTenants) * 100) : 100

    // BigInt → number for JSON cache serialization
    const totalStorageBytes = summary.reduce(
      (acc, s) => acc + Number(s.storage_used_bytes),
      0,
    )
    const totalActiveUsers = summary.reduce((acc, s) => acc + s.active_members, 0)
    const totalSeats = summary.reduce((acc, s) => acc + (s.max_members ?? 0), 0)

    const geoRow = geoRows[0] ?? { total_requests: 0, platform_cost: '0' }

    return {
      activeTenants,
      inactiveTenants,
      healthPct,
      totalStorageBytes,
      totalActiveUsers,
      totalSeats,
      geoMonthRequests: geoRow.total_requests,
      geoMonthPlatformCost: geoRow.platform_cost,
      recentTenants: recentTenants.map((t) => ({
        id: t.id,
        name: t.name,
        created_at: t.created_at.toISOString(),
        plan_display_name: t.plans?.display_name ?? null,
      })),
      recentByos: recentByos.map((p) => ({
        id: p.id,
        nickname: p.nickname ?? p.provider_type,
        tenant_name: p.tenants.name,
        updated_at: p.updated_at.toISOString(),
      })),
    }
  },
  ['dashboard-kpis'],
  { revalidate: 60 },
)

export default async function DashboardPage() {
  const t = getT('dashboard')
  const tc = getT('common')
  const [kpis, analytics] = await Promise.all([
    getDashboardKpis(),
    getActivityStats(),
  ])

  const healthHighlight =
    kpis.healthPct >= 90 ? 'success' : kpis.healthPct >= 70 ? 'warning' : 'danger'

  return (
    <>
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-2xl font-bold text-gray-900">{t('dashboard.title', 'Visió general')}</h1>
        <Link
          href="/dashboard/tenants/new"
          className="text-xs font-medium px-3 py-1.5 rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 transition"
        >
          {tc('common.new_tenant', '+ Nou tenant')}
        </Link>
      </div>

      {/* KPI Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-4">
        <KpiCard
          icon="🏢"
          label={t('dashboard.kpis.active_tenants', 'Tenants actius')}
          value={kpis.activeTenants}
          sub={kpis.inactiveTenants > 0 ? `${kpis.inactiveTenants} inactius` : undefined}
        />
        <KpiCard
          icon="🩺"
          label={t('dashboard.kpis.health', 'Salut plataforma')}
          value={`${kpis.healthPct}%`}
          sub={t('dashboard.kpis.health_sub', 'Tenants amb owner actiu')}
          highlight={healthHighlight}
        />
        <KpiCard
          icon="💾"
          label={t('dashboard.kpis.storage', 'Emmagatzematge intern')}
          value={formatBytes(kpis.totalStorageBytes)}
          sub={t('dashboard.kpis.storage_sub', 'Committed + reserved')}
        />
        <KpiCard
          icon="👥"
          label={t('dashboard.kpis.users', 'Usuaris actius')}
          value={kpis.totalActiveUsers}
          sub={kpis.totalSeats > 0 ? `de ${kpis.totalSeats} places totals` : undefined}
        />
      </div>

      {/* Geocoding KPIs */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 mb-8">
        <KpiCard
          icon="🗺️"
          label={t('dashboard.kpis.geo_requests', 'Geocoding (mes actual)')}
          value={kpis.geoMonthRequests.toLocaleString('ca-ES')}
          sub={t('dashboard.kpis.geo_requests_sub', 'Peticions search + reverse')}
        />
        <KpiCard
          icon="💶"
          label={t('dashboard.kpis.geo_cost', 'Cost geocoding platform')}
          value={`€${Number(kpis.geoMonthPlatformCost).toFixed(4)}`}
          sub={t('dashboard.kpis.geo_cost_sub', 'Cost facturable acumulat')}
        />
      </div>

      {/* Recent activity */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {/* Recent tenants */}
        <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
          <div className="px-6 py-4 border-b border-gray-50 flex items-center justify-between">
            <h2 className="text-sm font-semibold text-gray-700">{t('dashboard.recent_tenants.title', 'Tenants recents')}</h2>
            <Link
              href="/dashboard/tenants"
              className="text-xs text-indigo-600 hover:text-indigo-800 font-medium"
            >
              {tc('common.see_all', 'Veure tots →')}
            </Link>
          </div>
          {kpis.recentTenants.length === 0 ? (
            <p className="px-6 py-8 text-sm text-gray-400 text-center">{t('dashboard.recent_tenants.empty', 'Sense dades')}</p>
          ) : (
            <ul className="divide-y divide-gray-50">
              {kpis.recentTenants.map((t) => (
                <li key={t.id} className="flex items-center justify-between px-6 py-3 hover:bg-gray-50">
                  <div>
                    <Link
                      href={`/dashboard/tenants/${t.id}`}
                      className="text-sm font-medium text-gray-800 hover:text-indigo-600"
                    >
                      {t.name}
                    </Link>
                    {t.plan_display_name && (
                      <p className="text-xs text-gray-400">{t.plan_display_name}</p>
                    )}
                  </div>
                  <span className="text-xs text-gray-400 tabular-nums whitespace-nowrap">
                    {new Date(t.created_at).toLocaleDateString('ca-ES')}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>

        {/* Recent verified BYOS providers */}
        <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
          <div className="px-6 py-4 border-b border-gray-50 flex items-center justify-between">
            <h2 className="text-sm font-semibold text-gray-700">{t('dashboard.recent_byos.title', 'BYOS verificats recents')}</h2>
            <Link
              href="/dashboard/storage"
              className="text-xs text-indigo-600 hover:text-indigo-800 font-medium"
            >
              {t('dashboard.recent_byos.see_storage', 'Veure storage →')}
            </Link>
          </div>
          {kpis.recentByos.length === 0 ? (
            <p className="px-6 py-8 text-sm text-gray-400 text-center">{t('dashboard.recent_byos.empty', 'Cap proveïdor BYOS verificat')}</p>
          ) : (
            <ul className="divide-y divide-gray-50">
              {kpis.recentByos.map((p) => (
                <li key={p.id} className="flex items-center justify-between px-6 py-3 hover:bg-gray-50">
                  <div>
                    <p className="text-sm font-medium text-gray-800">{p.nickname}</p>
                    <p className="text-xs text-gray-400">{p.tenant_name}</p>
                  </div>
                  <span className="text-xs text-gray-400 tabular-nums whitespace-nowrap">
                    {new Date(p.updated_at).toLocaleDateString('ca-ES')}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>

      {/* ── Analytics section ─────────────────────────────────────────────── */}
      <div className="mt-8">
        <h2 className="text-base font-semibold text-gray-800 mb-4">Activitat d&apos;usuaris</h2>

        {/* Charts row */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-6">
          <NewUsersChart data={analytics.newUsersPerDay} />
          <ActivityBucketsChart data={analytics.buckets} />
        </div>

        {/* At-risk table — full width */}
        <AtRiskUsersTable users={analytics.atRiskUsers} />
      </div>
    </>
  )
}

