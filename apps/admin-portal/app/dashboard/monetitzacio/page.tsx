import Link from 'next/link'
import { prisma } from '@/lib/prisma'
import { PlanDistributionChart, type PlanSlice } from '@/components/dashboard/PlanDistributionChart'
import { getT } from '@/lib/i18n/server'

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`
  return `${(n / 1024 ** 3).toFixed(2)} GB`
}

export default async function MonetitzacioPage() {
  const t = getT('monetitzacio')
  const summary = await prisma.billing_summary.findMany({
    orderBy: { tenant_name: 'asc' },
  })

  // ── MRR ──────────────────────────────────────────────────────────────────
  const mrr = summary
    .filter((s) => s.is_active && s.price_monthly !== null)
    .reduce((acc, s) => acc + Number(s.price_monthly!), 0)

  // ── Plan distribution ─────────────────────────────────────────────────────
  const planMap = new Map<string, PlanSlice>()
  for (const s of summary) {
    const key = s.plan_name ?? '__sense_pla__'
    const display = s.plan_display_name ?? 'Sense pla'
    if (!planMap.has(key)) planMap.set(key, { name: key, display_name: display, count: 0, mrr: 0 })
    const g = planMap.get(key)!
    g.count++
    if (s.is_active && s.price_monthly) g.mrr += Number(s.price_monthly)
  }
  const planDistribution = Array.from(planMap.values()).sort((a, b) => b.count - a.count)

  // ── Top 10 egress this month ───────────────────────────────────────────────
  const topEgress = [...summary]
    .sort(
      (a, b) =>
        Number(b.egress_bytes_current_month) - Number(a.egress_bytes_current_month),
    )
    .slice(0, 10)
    .filter((s) => Number(s.egress_bytes_current_month) > 0)

  // ── Geocoding this month ─────────────────────────────────────────────────
  const [geoTotals, geoTopCost, geoTopVolume] = await Promise.all([
    prisma.$queryRaw<Array<{
      platform_cost: string
      byo_cost: string
      total_requests: number
    }>>`
      SELECT
        COALESCE(SUM(CASE WHEN billing_source = 'platform' THEN cost_amount ELSE 0 END), 0)::text AS platform_cost,
        COALESCE(SUM(CASE WHEN billing_source = 'byo'      THEN cost_amount ELSE 0 END), 0)::text AS byo_cost,
        COALESCE(COUNT(*), 0)::integer AS total_requests
      FROM data.geocoding_usage_ledger
      WHERE created_at >= date_trunc('month', now())
        AND created_at <  date_trunc('month', now()) + INTERVAL '1 month'
    `,
    prisma.$queryRaw<Array<{
      tenant_id: string
      tenant_name: string
      cost: string
      requests: number
    }>>`
      SELECT
        l.tenant_id::text,
        t.name AS tenant_name,
        SUM(l.cost_amount)::text AS cost,
        COUNT(*)::integer AS requests
      FROM data.geocoding_usage_ledger l
      JOIN data.tenants t ON t.id = l.tenant_id
      WHERE l.billing_source = 'platform'
        AND l.created_at >= date_trunc('month', now())
        AND l.created_at <  date_trunc('month', now()) + INTERVAL '1 month'
      GROUP BY l.tenant_id, t.name
      ORDER BY SUM(l.cost_amount) DESC
      LIMIT 10
    `,
    prisma.$queryRaw<Array<{
      tenant_id: string
      tenant_name: string
      total_requests: number
    }>>`
      SELECT
        m.tenant_id::text,
        t.name AS tenant_name,
        SUM(m.total_requests)::integer AS total_requests
      FROM data.geocoding_usage_monthly m
      JOIN data.tenants t ON t.id = m.tenant_id
      WHERE m.usage_month = date_trunc('month', now())::date
      GROUP BY m.tenant_id, t.name
      ORDER BY SUM(m.total_requests) DESC
      LIMIT 10
    `,
  ])

  const geoTotal = geoTotals[0] ?? { platform_cost: '0', byo_cost: '0', total_requests: 0 }

  // ── Storage upsell candidates (> 80 % quota used) ─────────────────────────
  const upsellCandidates = summary
    .filter((s) => {
      if (!s.max_storage_mb || !s.is_active) return false
      const limitBytes = s.max_storage_mb * 1024 * 1024
      return Number(s.storage_used_bytes) / limitBytes > 0.8
    })
    .sort((a, b) => {
      const ratioA = Number(a.storage_used_bytes) / (a.max_storage_mb! * 1024 * 1024)
      const ratioB = Number(b.storage_used_bytes) / (b.max_storage_mb! * 1024 * 1024)
      return ratioB - ratioA
    })

  return (
    <>
      <h1 className="text-2xl font-bold text-gray-900 mb-6">{t('monetitzacio.title', 'Monetització')}</h1>

      {/* Top KPI: MRR */}
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-8">
        <div className="bg-indigo-600 text-white rounded-2xl p-5 shadow-sm col-span-1">
          <p className="text-xs font-medium text-indigo-200 uppercase tracking-wide mb-1">{t('monetitzacio.mrr.label', 'MRR estimat')}</p>
          <p className="text-4xl font-bold">€{mrr.toFixed(2)}</p>
          <p className="text-xs text-indigo-200 mt-1">{t('monetitzacio.mrr.subtitle', 'Ingressos mensuals recurrents')}</p>
        </div>
        <div className="bg-white rounded-2xl border border-gray-100 p-5 shadow-sm">
          <p className="text-xs font-medium text-gray-400 uppercase tracking-wide mb-1">{t('monetitzacio.active_tenants.label', 'Tenants actius')}</p>
          <p className="text-3xl font-bold text-gray-900">
            {summary.filter((s) => s.is_active).length}
          </p>
          <p className="text-xs text-gray-400 mt-1">de {summary.length} totals</p>
        </div>
        <div className="bg-white rounded-2xl border border-gray-100 p-5 shadow-sm">
          <p className="text-xs font-medium text-gray-400 uppercase tracking-wide mb-1">{t('monetitzacio.upsell_candidates.label', 'Candidats upsell')}</p>
          <p className={`text-3xl font-bold ${upsellCandidates.length > 0 ? 'text-amber-600' : 'text-gray-900'}`}>
            {upsellCandidates.length}
          </p>
          <p className="text-xs text-gray-400 mt-1">{t('monetitzacio.upsell_candidates.subtitle', 'Tenants > 80 % de quota')}</p>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-6">
        {/* Plan distribution chart */}
        <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
          <div className="px-6 py-4 border-b border-gray-50">
            <h2 className="text-sm font-semibold text-gray-700">{t('monetitzacio.plan_distribution.title', 'Distribució per pla')}</h2>
          </div>
          <div className="p-4">
            {planDistribution.length === 0 ? (
              <p className="text-sm text-gray-400 text-center py-8">{t('monetitzacio.plan_distribution.empty', 'Sense dades')}</p>
            ) : (
              <>
                <PlanDistributionChart data={planDistribution} />
                <table className="w-full text-sm mt-4">
                  <thead>
                    <tr className="border-b border-gray-100">
                      <th className="text-left py-2 text-xs font-medium text-gray-400">{t('monetitzacio.plan_distribution.columns.plan', 'Pla')}</th>
                      <th className="text-right py-2 text-xs font-medium text-gray-400">{t('monetitzacio.plan_distribution.columns.tenants', 'Tenants')}</th>
                      <th className="text-right py-2 text-xs font-medium text-gray-400">{t('monetitzacio.plan_distribution.columns.mrr', 'MRR')}</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-50">
                    {planDistribution.map((p) => (
                      <tr key={p.name}>
                        <td className="py-2 text-gray-700">{p.display_name}</td>
                        <td className="py-2 text-right tabular-nums text-gray-600">{p.count}</td>
                        <td className="py-2 text-right tabular-nums text-gray-600">
                          €{p.mrr.toFixed(2)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </>
            )}
          </div>
        </div>

        {/* Storage upsell candidates */}
        <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
          <div className="px-6 py-4 border-b border-gray-50">
            <h2 className="text-sm font-semibold text-gray-700">{t('monetitzacio.upsell_section.title', 'Candidats a upsell de storage')}</h2>
            <p className="text-xs text-gray-400 mt-0.5">{t('monetitzacio.upsell_section.subtitle', "Tenants que superen el 80 % de la seva quota")}</p>
          </div>
          {upsellCandidates.length === 0 ? (
            <p className="px-6 py-8 text-sm text-gray-400 text-center">
              {t('monetitzacio.upsell_section.empty', 'Cap tenant supera el 80 % de la quota de storage ✓')}
            </p>
          ) : (
            <div className="divide-y divide-gray-50">
              {upsellCandidates.map((s) => {
                const limitBytes = s.max_storage_mb! * 1024 * 1024
                const usedBytes = Number(s.storage_used_bytes)
                const pct = Math.round((usedBytes / limitBytes) * 100)
                return (
                  <div key={s.tenant_id} className="px-6 py-3 hover:bg-gray-50">
                    <div className="flex items-center justify-between mb-1">
                      <Link
                        href={`/dashboard/tenants/${s.tenant_id}`}
                        className="text-sm font-medium text-gray-800 hover:text-indigo-600"
                      >
                        {s.tenant_name}
                      </Link>
                      <span
                        className={`text-xs font-semibold tabular-nums ${
                          pct >= 100 ? 'text-red-600' : 'text-amber-600'
                        }`}
                      >
                        {pct}%
                      </span>
                    </div>
                    <div className="h-1.5 rounded-full bg-gray-100">
                      <div
                        className={`h-1.5 rounded-full ${pct >= 100 ? 'bg-red-500' : 'bg-amber-400'}`}
                        style={{ width: `${Math.min(pct, 100)}%` }}
                      />
                    </div>
                    <p className="text-xs text-gray-400 mt-1">
                      {formatBytes(usedBytes)} / {formatBytes(limitBytes)} · {s.plan_display_name ?? '—'}
                    </p>
                  </div>
                )
              })}
            </div>
          )}
        </div>
      </div>

      {/* Top egress this month */}
      {topEgress.length > 0 && (
        <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
          <div className="px-6 py-4 border-b border-gray-50">
            <h2 className="text-sm font-semibold text-gray-700">{t('monetitzacio.egress_section.title', 'Top egress (mes actual)')}</h2>
            <p className="text-xs text-gray-400 mt-0.5">{t('monetitzacio.egress_section.subtitle', 'Tenants amb major consum de descàrregues')}</p>
          </div>
          <div className="divide-y divide-gray-50">
            {topEgress.map((s, i) => (
              <div key={s.tenant_id} className="flex items-center gap-4 px-6 py-3 hover:bg-gray-50">
                <span className="w-5 shrink-0 text-xs font-bold text-gray-400 tabular-nums">{i + 1}</span>
                <div className="flex-1 min-w-0">
                  <Link
                    href={`/dashboard/tenants/${s.tenant_id}`}
                    className="text-sm font-medium text-gray-800 hover:text-indigo-600 truncate block"
                  >
                    {s.tenant_name}
                  </Link>
                  <p className="text-xs text-gray-400">{s.plan_display_name ?? t('monetitzacio.upsell_section.no_plan', 'Sense pla')}</p>
                </div>
                <span className="text-sm tabular-nums text-gray-600 font-medium shrink-0">
                  {formatBytes(Number(s.egress_bytes_current_month))}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}
    </>
  )
}
