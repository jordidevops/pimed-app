import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import {
  Bar,
  BarChart,
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import { Label } from '@/components/ui/label'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { useTenant } from '@/contexts/TenantContext'
import { usePermission } from '@/hooks/usePermission'
import { useTenantFeatures } from '@/features/entity-timeline/api/useTenantFeatures'
import type { AnalyticsMetric } from '../api/recruitmentService'
import { useJobPostings, useRecruitmentAnalytics } from '../api/useRecruitment'

function formatMetric(m: AnalyticsMetric | undefined, suffix = ''): string {
  if (!m || m.suppressed || m.value === null || m.value === undefined) return '—'
  return `${m.value}${suffix}`
}

function Kpi({
  label,
  value,
  hint,
}: {
  label: string
  value: string
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
  emptyLabel,
}: {
  title: string
  rows: Array<{ key: string; label?: string; count: number }>
  emptyLabel: string
}) {
  if (!rows.length) {
    return (
      <div>
        <h3 className="text-sm font-semibold text-foreground mb-2">{title}</h3>
        <p className="text-sm text-muted-foreground">{emptyLabel}</p>
      </div>
    )
  }
  return (
    <div>
      <h3 className="text-sm font-semibold text-foreground mb-2">{title}</h3>
      <ul className="divide-y border-y">
        {rows.slice(0, 12).map((r) => (
          <li
            key={r.key}
            className="flex items-center justify-between py-2 text-sm gap-3"
          >
            <span className="truncate text-foreground">{r.label ?? r.key}</span>
            <span className="tabular-nums text-muted-foreground shrink-0">{r.count}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}

export function RecruitmentAnalyticsPage() {
  const { t } = useTranslation('recruitment')
  const { sites = [] } = useTenant()
  const canView = usePermission('recruitment.view')
  const { data: features, isLoading: featuresLoading } = useTenantFeatures()
  const { data: postings = [] } = useJobPostings()

  const [siteId, setSiteId] = useState('')
  const [postingId, setPostingId] = useState('')
  const [periodDays, setPeriodDays] = useState(90)

  const filters = useMemo(() => {
    const to = new Date()
    const from = new Date()
    from.setDate(from.getDate() - (periodDays - 1))
    // Local calendar date (avoid UTC day-shift from toISOString)
    const isoLocal = (d: Date) => {
      const y = d.getFullYear()
      const m = String(d.getMonth() + 1).padStart(2, '0')
      const day = String(d.getDate()).padStart(2, '0')
      return `${y}-${m}-${day}`
    }
    return {
      from: isoLocal(from),
      to: isoLocal(to),
      siteId: siteId || null,
      jobPostingId: postingId || null,
      departmentId: null as string | null,
    }
  }, [siteId, postingId, periodDays])

  const { data, isLoading, isError, error } = useRecruitmentAnalytics(filters)

  const funnelChart = useMemo(() => {
    if (!data?.funnel) return []
    return data.funnel.map((s) => ({
      key: s.key,
      label: t(`analytics.funnel.${s.key}`, s.key),
      count: s.suppressed || s.count === null ? null : s.count,
    }))
  }, [data?.funnel, t])

  const monthChart = useMemo(() => {
    if (!data?.by_month) return []
    return data.by_month.map((m) => ({
      key: m.key,
      applications: m.applications_suppressed ? null : m.applications,
      hires: m.hires_suppressed ? null : m.hires,
    }))
  }, [data?.by_month])

  if (featuresLoading) {
    return (
      <div className="p-6 flex items-center gap-2 text-muted-foreground">
        <Loader2 className="h-4 w-4 animate-spin" />
        {t('analytics.loading')}
      </div>
    )
  }

  if (!features?.recruitment_enabled) {
    return (
      <div className="p-6">
        <p className="text-muted-foreground">{t('postings.disabled')}</p>
      </div>
    )
  }

  if (!canView) {
    return (
      <div className="p-6">
        <p className="text-muted-foreground">{t('analytics.forbidden')}</p>
      </div>
    )
  }

  return (
    <div className="space-y-8">
      <p className="text-sm text-muted-foreground max-w-xl">
        {t('analytics.k_hint', { n: data?.min_cohort ?? 5 })}
      </p>

      <div className="flex flex-wrap gap-4 items-end">
        <div className="space-y-1.5 min-w-[10rem]">
          <Label>{t('analytics.filter_period')}</Label>
          <Select
            value={String(periodDays)}
            onValueChange={(v) => setPeriodDays(Number(v))}
          >
            <SelectTrigger>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="30">{t('analytics.period_30')}</SelectItem>
              <SelectItem value="90">{t('analytics.period_90')}</SelectItem>
              <SelectItem value="180">{t('analytics.period_180')}</SelectItem>
              <SelectItem value="365">{t('analytics.period_365')}</SelectItem>
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1.5 min-w-[12rem]">
          <Label>{t('analytics.filter_site')}</Label>
          <Select
            value={siteId || '__all__'}
            onValueChange={(v) => setSiteId(v === '__all__' ? '' : v)}
          >
            <SelectTrigger>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="__all__">{t('analytics.all_sites')}</SelectItem>
              {sites.map((s) => (
                <SelectItem key={s.id} value={s.id}>
                  {s.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1.5 min-w-[14rem]">
          <Label>{t('analytics.filter_posting')}</Label>
          <Select
            value={postingId || '__all__'}
            onValueChange={(v) => setPostingId(v === '__all__' ? '' : v)}
          >
            <SelectTrigger>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="__all__">{t('analytics.all_postings')}</SelectItem>
              {postings.map((p) => (
                <SelectItem key={p.id} value={p.id}>
                  {p.title}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      {isLoading ? (
        <div className="flex items-center gap-2 text-muted-foreground py-8">
          <Loader2 className="h-4 w-4 animate-spin" />
          {t('analytics.loading')}
        </div>
      ) : isError ? (
        <p className="text-sm text-destructive">
          {(error as Error)?.message || t('analytics.error')}
        </p>
      ) : data ? (
        <>
          <div className="flex flex-wrap gap-6 py-4 border-y">
            <Kpi
              label={t('analytics.kpi_applications')}
              value={formatMetric(data.kpis.applications)}
            />
            <Kpi
              label={t('analytics.kpi_active_postings')}
              value={formatMetric(data.kpis.active_postings)}
            />
            <Kpi label={t('analytics.kpi_hires')} value={formatMetric(data.kpis.hires)} />
            <Kpi
              label={t('analytics.kpi_conversion')}
              value={formatMetric(data.kpis.conversion_pct, '%')}
            />
            <Kpi
              label={t('analytics.kpi_avg_interview')}
              value={formatMetric(data.kpis.avg_days_to_first_interview)}
              hint={t('analytics.days')}
            />
            <Kpi
              label={t('analytics.kpi_avg_hire')}
              value={formatMetric(data.kpis.avg_days_to_hire)}
              hint={t('analytics.days')}
            />
          </div>

          <div className="grid gap-8 lg:grid-cols-2">
            <div>
              <h3 className="text-sm font-semibold mb-3">{t('analytics.funnel_title')}</h3>
              <div className="h-56 w-full">
                <ResponsiveContainer width="100%" height="100%">
                  <BarChart data={funnelChart}>
                    <CartesianGrid strokeDasharray="3 3" className="stroke-muted" />
                    <XAxis dataKey="label" tick={{ fontSize: 12 }} />
                    <YAxis allowDecimals={false} tick={{ fontSize: 12 }} />
                    <Tooltip
                      formatter={(value) =>
                        value === null || value === undefined ? '—' : String(value)
                      }
                    />
                    <Bar dataKey="count" fill="hsl(var(--primary))" radius={[4, 4, 0, 0]} />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </div>
            <div>
              <h3 className="text-sm font-semibold mb-3">{t('analytics.timeline_title')}</h3>
              <div className="h-56 w-full">
                <ResponsiveContainer width="100%" height="100%">
                  <LineChart data={monthChart}>
                    <CartesianGrid strokeDasharray="3 3" className="stroke-muted" />
                    <XAxis dataKey="key" tick={{ fontSize: 11 }} />
                    <YAxis allowDecimals={false} tick={{ fontSize: 12 }} />
                    <Tooltip
                      formatter={(value) =>
                        value === null || value === undefined ? '—' : String(value)
                      }
                    />
                    <Line
                      type="monotone"
                      dataKey="applications"
                      name={t('analytics.kpi_applications')}
                      stroke="hsl(var(--primary))"
                      strokeWidth={2}
                      connectNulls={false}
                    />
                    <Line
                      type="monotone"
                      dataKey="hires"
                      name={t('analytics.kpi_hires')}
                      stroke="hsl(var(--muted-foreground))"
                      strokeWidth={2}
                      connectNulls={false}
                    />
                  </LineChart>
                </ResponsiveContainer>
              </div>
            </div>
          </div>

          <div className="grid gap-8 sm:grid-cols-2 lg:grid-cols-3">
            <BreakdownList
              title={t('analytics.by_source')}
              rows={data.by_source}
              emptyLabel={t('analytics.empty_breakdown')}
            />
            <BreakdownList
              title={t('analytics.by_import')}
              rows={data.by_import_source_label}
              emptyLabel={t('analytics.empty_breakdown')}
            />
            <BreakdownList
              title={t('analytics.by_posting')}
              rows={data.by_posting}
              emptyLabel={t('analytics.empty_breakdown')}
            />
            <BreakdownList
              title={t('analytics.by_site')}
              rows={data.by_site}
              emptyLabel={t('analytics.empty_breakdown')}
            />
          </div>
        </>
      ) : null}
    </div>
  )
}
