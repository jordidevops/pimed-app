'use client'

import Link from 'next/link'
import { useMemo, useState, useTransition } from 'react'
import {
  getSigningOpsLogs,
  markSigningOpsLogResolved,
  runSigningArtifactReconcileNow,
  runCommercialDecisionReconcileNow,
  type GetSigningOpsLogsParams,
  type SigningOpsDashboard,
  type SigningOpsLogsResult,
  type TenantOption,
} from '@/app/admin/actions/signing-ops'
import {
  buildSigningOpsAlerts,
  type SigningOpsAlert,
} from '@/lib/signingOpsAlerts'

function formatAge(seconds: number | null): string {
  if (seconds == null) return '—'
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`
  return `${Math.floor(seconds / 86400)}d`
}

function Card({
  title,
  children,
  tone = 'default',
}: {
  title: string
  children: React.ReactNode
  tone?: 'default' | 'warn' | 'ok' | 'danger'
}) {
  const border =
    tone === 'warn'
      ? 'border-amber-200'
      : tone === 'ok'
        ? 'border-emerald-200'
        : tone === 'danger'
          ? 'border-red-200'
          : 'border-gray-100'
  return (
    <section className={`rounded-2xl border bg-white p-5 shadow-sm ${border}`}>
      <h2 className="text-sm font-semibold text-gray-900">{title}</h2>
      <div className="mt-3 space-y-2 text-sm text-gray-700">{children}</div>
    </section>
  )
}

function AttentionPanel({ alerts }: { alerts: SigningOpsAlert[] }) {
  if (alerts.length === 0) {
    return (
      <section className="rounded-2xl border border-emerald-200 bg-emerald-50/60 p-4">
        <h2 className="text-sm font-semibold text-emerald-900">Cal atenció</h2>
        <p className="mt-1 text-sm text-emerald-800">Tot en ordre amb els llindars actuals.</p>
      </section>
    )
  }

  return (
    <section className="rounded-2xl border border-amber-200 bg-amber-50/50 p-4">
      <h2 className="text-sm font-semibold text-gray-900">Cal atenció</h2>
      <p className="mt-1 text-xs text-gray-500">
        Resum automàtic a partir del dashboard (llindars fixos). No substitueix PagerDuty.
      </p>
      <ul className="mt-3 space-y-2">
        {alerts.map((a) => {
          const tone =
            a.severity === 'danger'
              ? 'border-red-200 bg-red-50 text-red-900'
              : a.severity === 'warn'
                ? 'border-amber-200 bg-amber-50 text-amber-950'
                : 'border-sky-200 bg-sky-50 text-sky-950'
          return (
            <li
              key={a.id}
              className={`rounded-xl border px-3 py-2 text-sm ${tone}`}
            >
              <p className="font-medium">{a.title}</p>
              <p className="mt-0.5 text-xs opacity-90">{a.hint}</p>
            </li>
          )
        })}
      </ul>
    </section>
  )
}

type Props = {
  initialDashboard: SigningOpsDashboard
  initialLogs: SigningOpsLogsResult
  tenants: TenantOption[]
  initialParams: GetSigningOpsLogsParams
}

export function SigningOpsDashboard({
  initialDashboard,
  initialLogs,
  tenants,
  initialParams,
}: Props) {
  const [dashboard] = useState(initialDashboard)
  const [logs, setLogs] = useState(initialLogs)
  const [params, setParams] = useState(initialParams)
  const [pending, startTransition] = useTransition()
  const [msg, setMsg] = useState<string | null>(null)

  const reconcileTone =
    dashboard.reconcile.backlog > 0
      ? 'warn'
      : dashboard.reconcile.last_ok === false
        ? 'danger'
        : 'ok'

  const attentionAlerts = useMemo(
    () =>
      buildSigningOpsAlerts({
        reconcile: dashboard.reconcile,
        anomalies: dashboard.anomalies,
      }),
    [dashboard.reconcile, dashboard.anomalies],
  )

  const tenantName = useMemo(() => {
    const map = new Map(tenants.map((t) => [t.id, t.name]))
    return (id: string | null | undefined) => (id ? map.get(id) ?? id.slice(0, 8) : '—')
  }, [tenants])

  function refresh(next: GetSigningOpsLogsParams = params) {
    startTransition(async () => {
      const data = await getSigningOpsLogs(next)
      setLogs(data)
      setParams(next)
    })
  }

  function onRunReconcile() {
    startTransition(async () => {
      setMsg(null)
      const res = await runSigningArtifactReconcileNow(50)
      if (!res.ok) {
        setMsg(res.message ?? 'Reconcile failed')
        return
      }
      setMsg('Reconcile executat')
      // Soft refresh logs/dashboard via navigation
      window.location.reload()
    })
  }

  function onResolve(id: string) {
    startTransition(async () => {
      const res = await markSigningOpsLogResolved(id)
      if (!res.ok) {
        setMsg(res.message ?? 'No s\'ha pogut marcar')
        return
      }
      refresh({ ...params })
    })
  }

  return (
    <div className="space-y-6">
      {msg && (
        <p className="rounded-lg bg-indigo-50 px-3 py-2 text-sm text-indigo-800">{msg}</p>
      )}

      <AttentionPanel alerts={attentionAlerts} />

      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <Card title="Reconcile artefactes" tone={reconcileTone}>
          <p>
            Backlog: <strong>{dashboard.reconcile.backlog}</strong>
          </p>
          <p>
            Darrera run:{' '}
            {dashboard.reconcile.last_ok == null
              ? '—'
              : dashboard.reconcile.last_ok
                ? 'OK'
                : 'FAIL'}
          </p>
          <p className="text-xs text-gray-500">
            Fa {formatAge(dashboard.reconcile.seconds_since_ok)} des de darrera OK
          </p>
          <p className="text-xs text-gray-500">
            listed {dashboard.reconcile.last_listed} · attempted{' '}
            {dashboard.reconcile.last_attempted} · attached{' '}
            {dashboard.reconcile.last_attached} · skipped {dashboard.reconcile.last_skipped}
          </p>
          {dashboard.reconcile.last_error && (
            <p className="text-xs text-red-600">{dashboard.reconcile.last_error}</p>
          )}
          <button
            type="button"
            disabled={pending}
            onClick={onRunReconcile}
            className="mt-2 rounded-lg bg-indigo-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-indigo-700 disabled:opacity-50"
          >
            Run reconcile now
          </button>
        </Card>

        <Card
          title="PDF DLQ"
          tone={dashboard.stats.pdf_dead_letters > 0 ? 'warn' : 'default'}
        >
          <p>
            Dead letters: <strong>{dashboard.stats.pdf_dead_letters}</strong>
          </p>
          <Link
            href="/dashboard/settings/pdf"
            className="text-xs text-indigo-600 hover:underline"
          >
            Obre config PDF →
          </Link>
        </Card>

        <Card title="Ús 30d">
          <p>
            Native: <strong>{dashboard.stats.submissions_30d.native}</strong>
          </p>
          <p>
            DocuSeal: <strong>{dashboard.stats.submissions_30d.docuseal}</strong>
          </p>
          <p className="text-xs text-gray-500">
            Bridge {dashboard.stats.bridge_vs_generic_30d.bridge} / DMS{' '}
            {dashboard.stats.bridge_vs_generic_30d.generic}
          </p>
          <p className="text-xs text-gray-500">
            Crèdits platform agregats: {dashboard.stats.platform_credits_total}
          </p>
        </Card>

        <Card title="Anomalies">
          <p>
            Stuck &gt;6h: <strong>{dashboard.anomalies.stuck_submissions}</strong>
          </p>
          <p>
            Open sense delivery:{' '}
            <strong>{dashboard.anomalies.open_requests_no_delivery}</strong>
          </p>
          <p>
            Open + artifact failed:{' '}
            <strong>{dashboard.anomalies.open_requests_artifact_failed}</strong>
          </p>
          <p className="text-xs text-gray-500">
            already_decided 24h: {dashboard.anomalies.already_decided_24h} · rate_limited
            24h: {dashboard.anomalies.rate_limited_24h}
          </p>
          <p className="text-xs text-gray-500">
            Commercial reconcile:{' '}
            {dashboard.anomalies.commercial_reconcile_last_ok == null
              ? '—'
              : dashboard.anomalies.commercial_reconcile_last_ok
                ? 'OK'
                : 'FAIL'}{' '}
            · findings {dashboard.anomalies.commercial_inconsistency_findings}
          </p>
          <button
            type="button"
            disabled={pending}
            onClick={() => {
              startTransition(async () => {
                setMsg(null)
                const res = await runCommercialDecisionReconcileNow(50)
                if (!res.ok) {
                  setMsg(res.message ?? 'Commercial reconcile failed')
                  return
                }
                setMsg('Commercial reconcile executat')
                window.location.reload()
              })
            }}
            className="mt-2 rounded-lg border border-gray-200 px-3 py-1.5 text-xs font-medium text-gray-800 hover:bg-gray-50 disabled:opacity-50"
          >
            Run commercial reconcile
          </button>
        </Card>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="Cues signing-related">
          <ul className="space-y-2">
            {dashboard.queues.map((q) => (
              <li key={q.queue_name} className="flex justify-between gap-3 text-xs">
                <span className="font-mono">{q.queue_name}</span>
                <span>
                  {q.available ? (
                    <>
                      len {q.queue_length} · oldest {formatAge(q.oldest_msg_age_sec)} · arch{' '}
                      {q.archive_count}
                    </>
                  ) : (
                    <span className="text-amber-700">n/d</span>
                  )}
                </span>
              </li>
            ))}
          </ul>
          <p className="pt-2 text-xs text-gray-500">
            Notificacions email de firma →{' '}
            <Link href="/dashboard/email-logs" className="text-indigo-600 hover:underline">
              Historial Emails
            </Link>
          </p>
        </Card>

        <Card title="Top fallades / spikes">
          <div className="grid gap-3 sm:grid-cols-2">
            <div>
              <p className="mb-1 text-xs font-medium text-gray-500">24h</p>
              <ul className="space-y-1 text-xs">
                {dashboard.anomalies.top_failures_24h.length === 0 && <li>—</li>}
                {dashboard.anomalies.top_failures_24h.map((r) => (
                  <li key={r.tenant_id} className="flex justify-between gap-2">
                    <Link
                      href={`/dashboard/signing-ops?tenantId=${r.tenant_id}`}
                      className="truncate text-indigo-600 hover:underline"
                    >
                      {r.tenant_name ?? r.tenant_id.slice(0, 8)}
                    </Link>
                    <span>{r.failures}</span>
                  </li>
                ))}
              </ul>
            </div>
            <div>
              <p className="mb-1 text-xs font-medium text-gray-500">Webhook spike</p>
              <ul className="space-y-1 text-xs">
                {dashboard.anomalies.webhook_spike_tenants.length === 0 && <li>—</li>}
                {dashboard.anomalies.webhook_spike_tenants.map((r) => (
                  <li key={r.tenant_id} className="flex justify-between gap-2">
                    <span className="truncate">{r.tenant_name ?? r.tenant_id.slice(0, 8)}</span>
                    <span>
                      {r.events_24h}/{r.avg_7d}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          </div>
          {dashboard.stats.low_credit_tenants.length > 0 && (
            <div className="pt-2">
              <p className="mb-1 text-xs font-medium text-gray-500">Crèdits baixos</p>
              <ul className="space-y-1 text-xs">
                {dashboard.stats.low_credit_tenants.slice(0, 5).map((t) => (
                  <li key={t.tenant_id} className="flex justify-between">
                    <Link
                      href={`/dashboard/tenants/${t.tenant_id}?tab=firmes`}
                      className="text-indigo-600 hover:underline"
                    >
                      {t.tenant_name}
                    </Link>
                    <span>{t.credits}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </Card>
      </div>

      <section className="rounded-2xl border border-gray-100 bg-white p-5 shadow-sm">
        <div className="mb-4 flex flex-wrap items-end justify-between gap-3">
          <div>
            <h2 className="text-sm font-semibold text-gray-900">Errors / operacions</h2>
            <p className="text-xs text-gray-500">
              `tenant_operation_logs` amb integration signing / pdf_generation
            </p>
          </div>
          <div className="flex flex-wrap gap-2 text-xs">
            <select
              className="rounded-lg border border-gray-200 px-2 py-1.5"
              value={params.tenantId ?? ''}
              onChange={(e) =>
                refresh({ ...params, page: 1, tenantId: e.target.value || undefined })
              }
            >
              <option value="">Tots els tenants</option>
              {tenants.map((t) => (
                <option key={t.id} value={t.id}>
                  {t.name}
                </option>
              ))}
            </select>
            <select
              className="rounded-lg border border-gray-200 px-2 py-1.5"
              value={params.status ?? ''}
              onChange={(e) =>
                refresh({ ...params, page: 1, status: e.target.value || undefined })
              }
            >
              <option value="">Tots els status</option>
              {['failed', 'dead_letter', 'degraded', 'success', 'pending', 'running'].map(
                (s) => (
                  <option key={s} value={s}>
                    {s}
                  </option>
                ),
              )}
            </select>
            <input
              className="rounded-lg border border-gray-200 px-2 py-1.5"
              placeholder="operation_code"
              defaultValue={params.operationCode ?? ''}
              onBlur={(e) =>
                refresh({
                  ...params,
                  page: 1,
                  operationCode: e.target.value.trim() || undefined,
                })
              }
            />
            <label className="inline-flex items-center gap-1 rounded-lg border border-gray-200 px-2 py-1.5">
              <input
                type="checkbox"
                checked={Boolean(params.unresolvedOnly)}
                onChange={(e) =>
                  refresh({ ...params, page: 1, unresolvedOnly: e.target.checked })
                }
              />
              Només unresolved
            </label>
          </div>
        </div>

        <div className="overflow-x-auto">
          <table className="min-w-full text-left text-xs">
            <thead className="border-b text-gray-500">
              <tr>
                <th className="px-2 py-2">Quan</th>
                <th className="px-2 py-2">Tenant</th>
                <th className="px-2 py-2">Op</th>
                <th className="px-2 py-2">Status</th>
                <th className="px-2 py-2">Error</th>
                <th className="px-2 py-2">Corr</th>
                <th className="px-2 py-2" />
              </tr>
            </thead>
            <tbody>
              {logs.rows.length === 0 && (
                <tr>
                  <td colSpan={7} className="px-2 py-6 text-center text-gray-400">
                    Sense registres
                  </td>
                </tr>
              )}
              {logs.rows.map((row) => (
                <tr key={row.id} className="border-b border-gray-50">
                  <td className="whitespace-nowrap px-2 py-2 text-gray-500">
                    {new Date(row.created_at).toLocaleString()}
                  </td>
                  <td className="px-2 py-2">
                    <Link
                      href={`/dashboard/tenants/${row.tenant_id}?tab=firmes`}
                      className="text-indigo-600 hover:underline"
                    >
                      {row.tenant_name ?? tenantName(row.tenant_id)}
                    </Link>
                  </td>
                  <td className="px-2 py-2 font-mono">
                    {row.integration_type}/{row.operation_code}
                  </td>
                  <td className="px-2 py-2">{row.status}</td>
                  <td className="max-w-[220px] truncate px-2 py-2" title={row.error_message ?? ''}>
                    {row.error_code ?? row.error_message ?? '—'}
                  </td>
                  <td className="max-w-[120px] truncate px-2 py-2 font-mono text-gray-500">
                    {row.correlation_id ?? row.entity_id ?? '—'}
                  </td>
                  <td className="px-2 py-2 text-right">
                    {!row.resolved_at &&
                      ['failed', 'dead_letter', 'degraded'].includes(row.status) && (
                        <button
                          type="button"
                          disabled={pending}
                          onClick={() => onResolve(row.id)}
                          className="text-indigo-600 hover:underline disabled:opacity-50"
                        >
                          Resolve
                        </button>
                      )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="mt-3 flex items-center justify-between text-xs text-gray-500">
          <span>
            {logs.total} files · pàg {logs.page}
          </span>
          <div className="flex gap-2">
            <button
              type="button"
              disabled={pending || logs.page <= 1}
              onClick={() => refresh({ ...params, page: logs.page - 1 })}
              className="rounded border px-2 py-1 disabled:opacity-40"
            >
              Prev
            </button>
            <button
              type="button"
              disabled={pending || logs.page * logs.pageSize >= logs.total}
              onClick={() => refresh({ ...params, page: logs.page + 1 })}
              className="rounded border px-2 py-1 disabled:opacity-40"
            >
              Next
            </button>
          </div>
        </div>
      </section>
    </div>
  )
}
