import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { BarChart3, Loader2 } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useDepartments } from '@/features/departments/api/useDepartments'
import { EmployeesComplianceDashboard } from '@/features/employees/components/EmployeesComplianceDashboard'
import { useHrReportingSummary } from '../api/useHrReportingSummary'
import { useTenantEmploymentContractAlerts } from '../api/useTenantEmploymentContractAlerts'
import type { HrBreakdownRow } from '../api/hrReportingService'

function Kpi({
  label,
  value,
  hint,
}: {
  label: string
  value: string | number
  hint?: string
}) {
  return (
    <div className="min-w-[8rem] flex-1">
      <p className="text-xs font-medium text-muted-foreground">{label}</p>
      <p className="text-2xl font-semibold tabular-nums text-foreground mt-0.5">{value}</p>
      {hint ? <p className="text-xs text-muted-foreground mt-1">{hint}</p> : null}
    </div>
  )
}

function BreakdownList({
  title,
  rows,
}: {
  title: string
  rows: HrBreakdownRow[]
}) {
  const { t } = useTranslation('employees')
  if (!rows.length) {
    return (
      <div>
        <h3 className="text-sm font-semibold text-foreground mb-2">{title}</h3>
        <p className="text-sm text-muted-foreground">
          {t('hr_reporting.empty_breakdown', 'Sense dades')}
        </p>
      </div>
    )
  }
  return (
    <div>
      <h3 className="text-sm font-semibold text-foreground mb-2">{title}</h3>
      <ul className="divide-y border-y">
        {rows.slice(0, 12).map((r, i) => (
          <li
            key={`${r.name}-${i}`}
            className="flex items-center justify-between py-2 text-sm gap-3"
          >
            <span className="truncate text-foreground">{r.name}</span>
            <span className="tabular-nums text-muted-foreground shrink-0">{r.count}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}

export function HrDashboardPage() {
  const { t } = useTranslation('employees')
  const { activeTenant, sites = [], tenantsLoading } = useTenant()
  const { data: departments = [] } = useDepartments()

  const [siteId, setSiteId] = useState('')
  const [departmentId, setDepartmentId] = useState('')
  const [periodDays, setPeriodDays] = useState(30)

  const filters = useMemo(
    () => ({
      siteId: siteId || null,
      departmentId: departmentId || null,
      periodDays,
    }),
    [siteId, departmentId, periodDays],
  )

  const { data: summary, isLoading, error } = useHrReportingSummary(filters)
  const { data: alertsReport, isLoading: alertsLoading } =
    useTenantEmploymentContractAlerts()

  if (tenantsLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    )
  }

  if (!activeTenant) {
    return (
      <div className="max-w-3xl mx-auto px-4 py-10">
        <p className="text-sm text-amber-800 bg-amber-50 border border-amber-200 rounded-2xl p-6 text-center">
          {t('employees.errors.no_tenant', 'Selecciona una organització')}
        </p>
      </div>
    )
  }

  const statusEntries = Object.entries(summary?.contracts_by_status ?? {}).sort(
    ([, a], [, b]) => b - a,
  )

  return (
    <div className="max-w-7xl mx-auto px-4 py-8 space-y-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="flex items-center gap-3 min-w-0">
          <div className="h-10 w-10 rounded-xl bg-primary/10 flex items-center justify-center shrink-0">
            <BarChart3 className="h-5 w-5 text-primary" aria-hidden />
          </div>
          <div className="min-w-0">
            <h1 className="text-xl font-bold text-foreground">
              {t('hr_reporting.title', 'Reporting HR')}
            </h1>
            <p className="text-sm text-muted-foreground">
              {t(
                'hr_reporting.subtitle',
                'Headcount per contracte efectiu, altes/baixes i alertes.',
              )}
            </p>
          </div>
        </div>
        <Link
          to="/employees"
          className="text-sm text-primary hover:underline shrink-0"
        >
          {t('hr_reporting.back_employees', '← Empleats')}
        </Link>
      </div>

      <div className="flex flex-wrap gap-3 items-end">
        <div>
          <label className="text-xs font-medium text-muted-foreground block mb-1">
            {t('employees.filter.site', 'Site')}
          </label>
          <select
            className="h-9 rounded-md border bg-background px-2 text-sm min-w-[10rem]"
            value={siteId}
            onChange={(e) => setSiteId(e.target.value)}
          >
            <option value="">{t('hr_reporting.all_sites', 'Tots')}</option>
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
            <option value="">{t('hr_reporting.all_depts', 'Tots')}</option>
            {departments.map((d) => (
              <option key={d.id} value={d.id ?? ''}>
                {d.name}
              </option>
            ))}
          </select>
        </div>
        <div>
          <label className="text-xs font-medium text-muted-foreground block mb-1">
            {t('hr_reporting.period', 'Període (dies)')}
          </label>
          <select
            className="h-9 rounded-md border bg-background px-2 text-sm"
            value={periodDays}
            onChange={(e) => setPeriodDays(Number(e.target.value))}
          >
            <option value={7}>7</option>
            <option value={30}>30</option>
            <option value={90}>90</option>
            <option value={365}>365</option>
          </select>
        </div>
      </div>

      {error ? (
        <p className="text-sm text-destructive">
          {t('hr_reporting.load_error', 'No s’ha pogut carregar el reporting.')}
        </p>
      ) : isLoading || !summary ? (
        <div className="flex items-center gap-2 text-sm text-muted-foreground py-8">
          <Loader2 className="h-4 w-4 animate-spin" />
          {t('hr_reporting.loading', 'Carregant KPIs…')}
        </div>
      ) : (
        <>
          <section className="flex flex-wrap gap-6 py-2 border-y">
            <Kpi
              label={t('hr_reporting.kpi.headcount', 'Headcount efectiu')}
              value={summary.headcount.effective}
              hint={
                summary.headcount.legacy_without_contract > 0
                  ? t(
                      'hr_reporting.kpi.legacy_gap',
                      '{{count}} actius sense contracte efectiu',
                      { count: summary.headcount.legacy_without_contract },
                    )
                  : undefined
              }
            />
            <Kpi
              label={t('hr_reporting.kpi.hires', 'Altes')}
              value={summary.hires}
              hint={t('hr_reporting.kpi.period_hint', 'Últims {{days}} dies', {
                days: summary.period_days,
              })}
            />
            <Kpi
              label={t('hr_reporting.kpi.terminations', 'Baixes')}
              value={summary.terminations}
            />
            <Kpi
              label={t('hr_reporting.kpi.expiring', 'Contractes ≤90d')}
              value={summary.contracts_expiring_90d}
            />
            <Kpi
              label={t('hr_reporting.kpi.incomplete', 'Perfils incomplets')}
              value={summary.incomplete_profiles}
            />
            <Kpi
              label={t('hr_reporting.kpi.onboarding', 'En onboarding')}
              value={summary.onboarding_count}
            />
          </section>

          <section className="grid gap-8 md:grid-cols-3">
            <BreakdownList
              title={t('hr_reporting.by_site', 'Per site')}
              rows={summary.by_site}
            />
            <BreakdownList
              title={t('hr_reporting.by_department', 'Per departament')}
              rows={summary.by_department}
            />
            <BreakdownList
              title={t('hr_reporting.by_position', 'Per lloc de treball')}
              rows={summary.by_job_position}
            />
          </section>

          <section>
            <h3 className="text-sm font-semibold text-foreground mb-2">
              {t('hr_reporting.contracts_status', 'Contractes per estat')}
            </h3>
            {statusEntries.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t('hr_reporting.empty_breakdown', 'Sense dades')}
              </p>
            ) : (
              <ul className="flex flex-wrap gap-x-6 gap-y-2 text-sm">
                {statusEntries.map(([status, count]) => (
                  <li key={status} className="tabular-nums">
                    <span className="text-muted-foreground">{status}: </span>
                    <span className="font-medium text-foreground">{count}</span>
                  </li>
                ))}
              </ul>
            )}
          </section>

          <section className="space-y-3">
            <h2 className="text-base font-semibold text-foreground">
              {t('hr_reporting.contract_alerts', 'Alertes de contractes')}
            </h2>
            {alertsLoading ? (
              <div className="flex items-center gap-2 text-sm text-muted-foreground">
                <Loader2 className="h-4 w-4 animate-spin" />
              </div>
            ) : !alertsReport?.alerts?.length ? (
              <p className="text-sm text-muted-foreground">
                {t('hr_reporting.no_contract_alerts', 'Cap alerta activa.')}
              </p>
            ) : (
              <ul className="divide-y border-y">
                {alertsReport.alerts.slice(0, 20).map((a, i) => (
                  <li
                    key={`${a.contract_id ?? i}-${a.kind}`}
                    className="py-2.5 text-sm flex flex-wrap gap-x-3 gap-y-1"
                  >
                    <span className="font-medium text-foreground">
                      {a.full_name ?? a.employee_id}
                    </span>
                    <span className="text-muted-foreground">{a.kind}</span>
                    {a.reason ? (
                      <span className="text-muted-foreground">{a.reason}</span>
                    ) : null}
                    {a.employee_id ? (
                      <Link
                        to={`/employees/${a.employee_id}?tab=contracts`}
                        className="text-primary hover:underline ml-auto"
                      >
                        {t('hr_reporting.open_employee', 'Obrir')}
                      </Link>
                    ) : null}
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}

      <section className="space-y-3 pt-2">
        <div>
          <h2 className="text-base font-semibold text-foreground">
            {t('hr_reporting.compliance_section', 'Compliment i readiness')}
          </h2>
          <p className="text-sm text-muted-foreground">
            {t(
              'hr_reporting.compliance_hint',
              'Vista CR-4 (certificacions i projecció readiness).',
            )}
          </p>
        </div>
        <EmployeesComplianceDashboard />
      </section>
    </div>
  )
}
