'use client'

import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from 'recharts'
import { useTranslation } from 'react-i18next'
import type { DailyVolumePoint } from '@/app/admin/actions/email-logs'

function formatMs(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)}ms`
  return `${(ms / 1000).toFixed(1)}s`
}

interface Props {
  data: DailyVolumePoint[]
}

export function EmailLatencyChart({ data }: Props) {
  const { t } = useTranslation('email_logs')
  const avgLatencyLabel = (() => {
    const translated = t('email_logs.stats.avg_latency', 'Latència Mitjana')
    return typeof translated === 'string' ? translated : 'Latència Mitjana'
  })()

  const toMs = (value: unknown): number => {
    if (typeof value === 'number' && Number.isFinite(value)) return value
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : 0
  }

  const hasData = data.some((d) => d.avg_processing_ms != null)

  if (!hasData) {
    return (
      <div className="flex h-24 items-center justify-center text-sm text-gray-400">
        {t('email_logs.stats.no_data', 'Sense dades per al període seleccionat')}
      </div>
    )
  }

  return (
    <ResponsiveContainer width="100%" height={200}>
      <LineChart data={data} margin={{ top: 4, right: 4, bottom: 0, left: -10 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f3f4f6" />
        <XAxis
          dataKey="day"
          tick={{ fontSize: 11, fill: '#6b7280' }}
          tickFormatter={(v) => String(v).slice(5).replace('-', '/')}
        />
        <YAxis
          tick={{ fontSize: 11, fill: '#6b7280' }}
          tickFormatter={(v) => formatMs(toMs(v))}
          allowDecimals={false}
        />
        <Tooltip
          formatter={(v) => [
            formatMs(toMs(v)),
            avgLatencyLabel,
          ]}
          labelFormatter={(l) => String(l).slice(5).replace('-', '/')}
        />
        <Line
          type="monotone"
          dataKey="avg_processing_ms"
          stroke="#6366f1"
          strokeWidth={2}
          dot={{ r: 3, fill: '#6366f1' }}
          connectNulls={false}
          name={avgLatencyLabel}
        />
      </LineChart>
    </ResponsiveContainer>
  )
}
