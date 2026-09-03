import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useDepartments } from '@/features/departments/api/useDepartments'
import { useReadinessProjectionSummary } from '../api/useReadinessProjectionSummary'
import { useReadinessProjectionList } from '../api/useReadinessProjectionList'
import {
  useTenantCertifications,
  type CertificationStatusFilter,
} from '../api/useTenantCertifications'

const STATUS_OPTIONS: CertificationStatusFilter[] = [
  '',
  'expired',
  'expiring_soon',
  'active',
  'indefinite',
  'not_yet_valid',
]

function reasonsText(reasons: unknown): string {
  if (Array.isArray(reasons)) return reasons.map(String).join(', ')
  return '—'
}

export function EmployeesComplianceDashboard() {
  const { t } = useTranslation('employees')
  const { sites = [] } = useTenant()
  const { data: departments = [] } = useDepartments()

  const [siteId, setSiteId] = useState('')
  const [departmentId, setDepartmentId] = useState('')
  const [status, setStatus] = useState<CertificationStatusFilter>('')

  const scopeFilters = useMemo(
    () => ({
      siteId: siteId || null,
      departmentId: departmentId || null,
    }),
    [siteId, departmentId],
  )

  const { data: summary, isLoading: summaryLoading } =
    useReadinessProjectionSummary(scopeFilters)
  const { data: blocked = [], isLoading: blockedLoading } = useReadinessProjectionList({
    isReady: false,
    siteId: scopeFilters.siteId,
    departmentId: scopeFilters.departmentId,
    limit: 25,
  })
  const { data: certs = [], isLoading: certsLoading } = useTenantCertifications({
    computedStatus: status,
    siteId: scopeFilters.siteId,
    departmentId: scopeFilters.departmentId,
  })

  const siteMap = useMemo(() => {
    const m = new Map<string, string>()
    for (const s of sites) m.set(s.id, s.name)
    return m
  }, [sites])

  const deptMap = useMemo(() => {
    const m = new Map<string, string>()
    for (const d of departments) m.set(d.id, d.name)
    return m
  }, [departments])

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap gap-2 items-end">
        <div>
          <label className="text-xs font-medium text-muted-foreground block mb-1">
            {t('employees.filter.site', 'Site')}
          </label>
          <select
            className="h-9 rounded-md border bg-background px-2 text-sm min-w-[10rem]"
            value={siteId}
            onChange={(e) => setSiteId(e.target.value)}
          >
            <option value="">{t('employees.filter.all_sites', 'Tots els sites')}</option>
            {sites.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        </div>
        <div>
          <label className="text-xs font-medium text-muted-foreground block mb-1">
            {t('employees.filter.department', 'Departament')}
          </label>
          <select
            className="h-9 rounded-md border bg-background px-2 text-sm min-w-[10rem]"
            value={departmentId}
            onChange={(e) => setDepartmentId(e.target.value)}
          >
            <option value="">
              {t('employees.filter.all_departments', 'Tots els departaments')}
            </option>
            {departments.map((d) => (
              <option key={d.id} value={d.id}>
                {d.name}
              </option>
            ))}
          </select>
        </div>
      </div>

      <div className="rounded-2xl border bg-card p-4 sm:p-5">
        {summaryLoading ? (
          <div className="flex items-center gap-2 text-sm text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin" />
            {t('employees.readiness.loading', 'Carregant readiness…')}
          </div>
        ) : summary ? (
          <div className="space-y-1">
            <p className="text-base font-semibold">
              {t('employees.readiness.projection_title', 'Readiness (projecció)')}
              {summary.ready_pct != null ? (
                <span className="ml-2 text-emerald-700">{summary.ready_pct}%</span>
              ) : null}
            </p>
            <p className="text-sm text-muted-foreground">
              {summary.ready}/{summary.total_employees}{' '}
              {t('employees.readiness.ready', 'elegibles')}
              {' · '}
              {summary.not_ready} {t('employees.readiness.not_ready', 'bloquejats')}
              {summary.missing_projection > 0
                ? ` · ${summary.missing_projection} ${t('employees.readiness.missing_projection', 'sense projecció')}`
                : ''}
            </p>
            <p className="text-[11px] text-muted-foreground/80">
              {t(
                'employees.readiness.projection_hint',
                'Agregat O(1) sobre employee_readiness_projection — no recalcula per empleat.',
              )}
            </p>
          </div>
        ) : null}
      </div>

      <div className="rounded-2xl border bg-card p-4 sm:p-5 space-y-3">
        <h3 className="text-sm font-semibold">
          {t('employees.readiness.blocked_list', 'Empleats no ready')}
        </h3>
        {blockedLoading ? (
          <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" />
        ) : blocked.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t('employees.readiness.blocked_empty', 'Cap empleat bloquejat amb projecció.')}
          </p>
        ) : (
          <ul className="divide-y rounded-xl border text-sm">
            {blocked.map((row) => (
              <li key={row.employee_id} className="px-3 py-2 flex flex-wrap justify-between gap-2">
                <div>
                  <Link
                    to={`/employees/${row.employee_id}`}
                    className="font-medium text-primary hover:underline"
                  >
                    {row.employee_name}
                  </Link>
                  <p className="text-xs text-muted-foreground">
                    {reasonsText(row.blocking_reasons)}
                  </p>
                </div>
                <span className="text-xs text-muted-foreground self-center">
                  {row.site_id ? siteMap.get(row.site_id) ?? '—' : '—'}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="rounded-2xl border bg-card p-4 sm:p-5 space-y-3">
        <div className="flex flex-wrap items-end justify-between gap-3">
          <h3 className="text-sm font-semibold">
            {t('employees.compliance.certs_global_title', 'Certificacions (tenant)')}
          </h3>
          <div>
            <label className="text-xs font-medium text-muted-foreground block mb-1">
              {t('employees.compliance.filter_status', 'Estat')}
            </label>
            <select
              className="h-9 rounded-md border bg-background px-2 text-sm"
              value={status}
              onChange={(e) => setStatus(e.target.value as CertificationStatusFilter)}
            >
              {STATUS_OPTIONS.map((s) => (
                <option key={s || 'all'} value={s}>
                  {s
                    ? t(`employees.compliance.status.${s}`, s)
                    : t('employees.compliance.status_all', 'Tots')}
                </option>
              ))}
            </select>
          </div>
        </div>

        {certsLoading ? (
          <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" />
        ) : (
          <div className="overflow-x-auto rounded-xl border">
            <table className="min-w-full text-sm">
              <thead className="bg-muted/50 text-left">
                <tr>
                  <th className="px-3 py-2 font-medium">
                    {t('employees.compliance.col_employee', 'Empleat')}
                  </th>
                  <th className="px-3 py-2 font-medium">
                    {t('employees.compliance.col_requirement', 'Requeriment')}
                  </th>
                  <th className="px-3 py-2 font-medium">
                    {t('employees.compliance.col_status', 'Estat')}
                  </th>
                  <th className="px-3 py-2 font-medium">
                    {t('employees.compliance.col_until', 'Fins')}
                  </th>
                  <th className="px-3 py-2 font-medium">
                    {t('employees.filter.site', 'Site')}
                  </th>
                </tr>
              </thead>
              <tbody>
                {certs.length === 0 ? (
                  <tr>
                    <td colSpan={5} className="px-3 py-6 text-center text-muted-foreground">
                      {t('employees.compliance.certs_empty', 'Cap certificació amb aquests filtres')}
                    </td>
                  </tr>
                ) : (
                  certs.map((row) => (
                    <tr key={row.id} className="border-t">
                      <td className="px-3 py-2">
                        <Link
                          to={`/employees/${row.employee_id}`}
                          className="text-primary hover:underline"
                        >
                          {row.employee_name}
                        </Link>
                      </td>
                      <td className="px-3 py-2">
                        <span className="font-medium">{row.requirement_name}</span>
                        <span className="text-xs text-muted-foreground ml-1">
                          ({row.requirement_code})
                        </span>
                      </td>
                      <td className="px-3 py-2">
                        {t(`employees.compliance.status.${row.computed_status}`, row.computed_status)}
                      </td>
                      <td className="px-3 py-2 text-muted-foreground">
                        {row.valid_until ?? '∞'}
                      </td>
                      <td className="px-3 py-2 text-muted-foreground">
                        {row.site_id ? siteMap.get(row.site_id) ?? '—' : '—'}
                        {row.department_id
                          ? ` · ${deptMap.get(row.department_id) ?? ''}`
                          : ''}
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}
