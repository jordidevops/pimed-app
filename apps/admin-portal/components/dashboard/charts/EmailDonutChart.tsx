'use client'

import { PieChart, Pie, Cell, Tooltip, Legend, ResponsiveContainer } from 'recharts'
import { useTranslation } from 'react-i18next'
import type { StatusTotal } from '@/app/admin/actions/email-logs'

const STATUS_COLORS: Record<string, string> = {
  delivered: '#10b981',
  sent: '#6366f1',
  bounced: '#f97316',
  failed: '#ef4444',
  processing: '#3b82f6',
  queued: '#9ca3af',
}

interface Props {
  data: StatusTotal[]
}

export function EmailDonutChart({ data }: Props) {
  const { t } = useTranslation('email_logs')

  const translateStatus = (rawStatus: unknown): string => {
    const status = String(rawStatus)
    const translated = t(`email_logs.status.${status}`, status)
    return typeof translated === 'string' ? translated : status
  }

  const total = data.reduce((sum, d) => sum + d.count, 0)

  if (total === 0) {
    return (
      <div className="flex h-48 items-center justify-center text-sm text-gray-400">
        {t('email_logs.stats.no_data', 'Sense dades per al període seleccionat')}
      </div>
    )
  }

  const delivered = data.find((d) => d.status === 'delivered')?.count ?? 0
  const successRate = Math.round((delivered / total) * 100)

  return (
    <div>
      <div className="text-center mb-1">
        <span className="text-3xl font-bold text-emerald-600">{successRate}%</span>
        <span className="ml-2 text-sm text-gray-500">
          {t('email_logs.stats.success_rate', "taxa d'èxit")}
        </span>
      </div>
      <ResponsiveContainer width="100%" height={160}>
        <PieChart>
          <Pie
            data={data}
            dataKey="count"
            nameKey="status"
            cx="50%"
            cy="50%"
            innerRadius={45}
            outerRadius={70}
            paddingAngle={2}
          >
            {data.map((entry) => (
              <Cell
                key={entry.status}
                fill={STATUS_COLORS[entry.status] ?? '#9ca3af'}
              />
            ))}
          </Pie>
          <Tooltip
            formatter={(value, name) => [
              value,
              translateStatus(name),
            ]}
          />
          <Legend
            iconSize={8}
            wrapperStyle={{ fontSize: '11px' }}
            formatter={(value) => translateStatus(value)}
          />
        </PieChart>
      </ResponsiveContainer>
    </div>
  )
}
