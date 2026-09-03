'use client'

import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from 'recharts'
import { useTranslation } from 'react-i18next'
import type { DailyVolumePoint } from '@/app/admin/actions/email-logs'

const STATUS_COLORS = {
  delivered: '#10b981',
  sent: '#6366f1',
  bounced: '#f97316',
  failed: '#ef4444',
  processing: '#3b82f6',
  queued: '#9ca3af',
} as const

interface Props {
  data: DailyVolumePoint[]
}

export function EmailVolumeChart({ data }: Props) {
  const { t } = useTranslation('email_logs')

  if (data.length === 0) {
    return (
      <div className="flex h-48 items-center justify-center text-sm text-gray-400">
        {t('email_logs.stats.no_data', 'Sense dades per al període seleccionat')}
      </div>
    )
  }

  const formatted = data.map((d) => ({
    ...d,
    day: new Date(d.day + 'T00:00:00').toLocaleDateString('ca-ES', {
      day: '2-digit',
      month: '2-digit',
    }),
  }))

  return (
    <ResponsiveContainer width="100%" height={200}>
      <BarChart data={formatted} margin={{ top: 4, right: 4, bottom: 0, left: -22 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f3f4f6" vertical={false} />
        <XAxis dataKey="day" tick={{ fontSize: 11, fill: '#6b7280' }} />
        <YAxis tick={{ fontSize: 11, fill: '#6b7280' }} allowDecimals={false} />
        <Tooltip />
        <Legend iconSize={8} wrapperStyle={{ fontSize: '11px', paddingTop: '8px' }} />
        <Bar
          dataKey="queued"
          stackId="a"
          fill={STATUS_COLORS.queued}
          name={t('email_logs.status.queued', 'En cua')}
        />
        <Bar
          dataKey="processing"
          stackId="a"
          fill={STATUS_COLORS.processing}
          name={t('email_logs.status.processing', 'Processant')}
        />
        <Bar
          dataKey="sent"
          stackId="a"
          fill={STATUS_COLORS.sent}
          name={t('email_logs.status.sent', 'Enviat')}
        />
        <Bar
          dataKey="delivered"
          stackId="a"
          fill={STATUS_COLORS.delivered}
          name={t('email_logs.status.delivered', 'Entregat')}
        />
        <Bar
          dataKey="bounced"
          stackId="a"
          fill={STATUS_COLORS.bounced}
          name={t('email_logs.status.bounced', 'Rebutjat')}
        />
        <Bar
          dataKey="failed"
          stackId="a"
          fill={STATUS_COLORS.failed}
          name={t('email_logs.status.failed', 'Error')}
        />
      </BarChart>
    </ResponsiveContainer>
  )
}
