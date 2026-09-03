'use client'

import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Cell,
} from 'recharts'
import { useTranslation } from 'react-i18next'
import type { AuditLogsStats } from '@/app/admin/actions/audit-logs'

// ---------------------------------------------------------------------------
// Color palette
// ---------------------------------------------------------------------------

const ACTION_COLORS: Record<string, string> = {
  TENANT_DEACTIVATED:        '#ef4444',
  TENANT_ACTIVATED:          '#10b981',
  TENANT_PLAN_CHANGED:       '#3b82f6',
  TENANT_STORAGE_BLOCKED:    '#f97316',
  TENANT_STORAGE_UNBLOCKED:  '#10b981',
  SITE_CREATED:              '#22c55e',
  SITE_DEACTIVATED:          '#ef4444',
  MEMBER_INVITED:            '#6366f1',
  MEMBER_ROLE_CHANGED:       '#a855f7',
  MEMBER_REMOVED:            '#ef4444',
  EMAIL_BODY_VIEWED:         '#eab308',
  FILE_DELETED:              '#ef4444',
  FILE_UPLOADED:             '#10b981',
}

const DEFAULT_BAR_COLOR = '#6366f1'

// ---------------------------------------------------------------------------
// Sub-components
// ---------------------------------------------------------------------------

function EmptyState({ label }: { label: string }) {
  return (
    <div className="flex h-36 items-center justify-center text-sm text-gray-400">
      {label}
    </div>
  )
}

function ChartCard({
  title,
  children,
}: {
  title: string
  children: React.ReactNode
}) {
  return (
    <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
      <div className="px-5 py-3 border-b border-gray-100">
        <h3 className="text-sm font-semibold text-gray-700">{title}</h3>
      </div>
      <div className="p-4">{children}</div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Per-day bar chart
// ---------------------------------------------------------------------------

function PerDayChart({
  data,
  noDataLabel,
}: {
  data: AuditLogsStats['perDay']
  noDataLabel: string
}) {
  if (data.length === 0) return <EmptyState label={noDataLabel} />

  const formatted = data.map((d) => ({
    ...d,
    day: new Date(d.date + 'T00:00:00').toLocaleDateString('ca-ES', {
      day: '2-digit',
      month: '2-digit',
    }),
  }))

  return (
    <ResponsiveContainer width="100%" height={180}>
      <BarChart data={formatted} margin={{ top: 4, right: 4, bottom: 0, left: -22 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f3f4f6" vertical={false} />
        <XAxis dataKey="day" tick={{ fontSize: 11, fill: '#6b7280' }} />
        <YAxis tick={{ fontSize: 11, fill: '#6b7280' }} allowDecimals={false} />
        <Tooltip
          contentStyle={{ fontSize: '12px', borderRadius: '8px', border: '1px solid #e5e7eb' }}
        />
        <Bar dataKey="count" fill={DEFAULT_BAR_COLOR} radius={[3, 3, 0, 0]} />
      </BarChart>
    </ResponsiveContainer>
  )
}

// ---------------------------------------------------------------------------
// Top actions bar chart (horizontal)
// ---------------------------------------------------------------------------

function TopActionsChart({
  data,
  noDataLabel,
}: {
  data: AuditLogsStats['topActions']
  noDataLabel: string
}) {
  if (data.length === 0) return <EmptyState label={noDataLabel} />

  return (
    <ResponsiveContainer width="100%" height={Math.max(180, data.length * 28)}>
      <BarChart
        layout="vertical"
        data={data}
        margin={{ top: 4, right: 20, bottom: 0, left: 4 }}
      >
        <CartesianGrid strokeDasharray="3 3" stroke="#f3f4f6" horizontal={false} />
        <XAxis type="number" tick={{ fontSize: 11, fill: '#6b7280' }} allowDecimals={false} />
        <YAxis
          type="category"
          dataKey="action"
          tick={{ fontSize: 10, fill: '#6b7280', fontFamily: 'monospace' }}
          width={170}
        />
        <Tooltip
          contentStyle={{ fontSize: '12px', borderRadius: '8px', border: '1px solid #e5e7eb' }}
        />
        <Bar dataKey="count" radius={[0, 3, 3, 0]}>
          {data.map((entry, index) => (
            <Cell
              key={`cell-${index}`}
              fill={ACTION_COLORS[entry.action] ?? DEFAULT_BAR_COLOR}
            />
          ))}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  )
}

// ---------------------------------------------------------------------------
// Top tenants bar chart (horizontal)
// ---------------------------------------------------------------------------

function TopTenantsChart({
  data,
  noDataLabel,
}: {
  data: AuditLogsStats['topTenants']
  noDataLabel: string
}) {
  if (data.length === 0) return <EmptyState label={noDataLabel} />

  const formatted = data.map((d) => ({
    ...d,
    name: d.tenant_name ?? d.tenant_id?.slice(0, 8) ?? '?',
  }))

  return (
    <ResponsiveContainer width="100%" height={Math.max(180, data.length * 28)}>
      <BarChart
        layout="vertical"
        data={formatted}
        margin={{ top: 4, right: 20, bottom: 0, left: 4 }}
      >
        <CartesianGrid strokeDasharray="3 3" stroke="#f3f4f6" horizontal={false} />
        <XAxis type="number" tick={{ fontSize: 11, fill: '#6b7280' }} allowDecimals={false} />
        <YAxis
          type="category"
          dataKey="name"
          tick={{ fontSize: 11, fill: '#6b7280' }}
          width={130}
        />
        <Tooltip
          contentStyle={{ fontSize: '12px', borderRadius: '8px', border: '1px solid #e5e7eb' }}
        />
        <Bar dataKey="count" fill="#6366f1" radius={[0, 3, 3, 0]} />
      </BarChart>
    </ResponsiveContainer>
  )
}

// ---------------------------------------------------------------------------
// AuditStatsPanel — exported component
// ---------------------------------------------------------------------------

interface Props {
  stats: AuditLogsStats
}

export function AuditStatsPanel({ stats }: Props) {
  const { t } = useTranslation('activity')
  const noData = t('activity.stats.no_data', 'Sense dades per al període seleccionat')

  return (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
      <ChartCard title={t('activity.stats.per_day_title', 'Logs per dia')}>
        <PerDayChart data={stats.perDay} noDataLabel={noData} />
      </ChartCard>

      <ChartCard title={t('activity.stats.top_actions_title', 'Accions més freqüents')}>
        <TopActionsChart data={stats.topActions} noDataLabel={noData} />
      </ChartCard>

      <ChartCard title={t('activity.stats.top_tenants_title', 'Top tenants per volum')}>
        <TopTenantsChart data={stats.topTenants} noDataLabel={noData} />
      </ChartCard>
    </div>
  )
}
