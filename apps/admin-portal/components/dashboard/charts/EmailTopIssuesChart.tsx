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
import type { TopIssue } from '@/app/admin/actions/email-logs'

const TRUNCATE_LEN = 22

interface Props {
  data: TopIssue[]
}

export function EmailTopIssuesChart({ data }: Props) {
  const { t } = useTranslation('email_logs')

  if (data.length === 0) {
    return (
      <div className="flex h-24 items-center justify-center text-sm text-gray-400">
        {t('email_logs.stats.no_data', 'Sense dades per al període seleccionat')}
      </div>
    )
  }

  const formatted = data.map((d) => ({
    ...d,
    label:
      d.label.length > TRUNCATE_LEN ? d.label.slice(0, TRUNCATE_LEN) + '…' : d.label,
    ok: d.total - d.errors,
  }))

  const chartHeight = Math.max(100, formatted.length * 44 + 30)

  return (
    <ResponsiveContainer width="100%" height={chartHeight}>
      <BarChart
        data={formatted}
        layout="vertical"
        margin={{ top: 4, right: 56, bottom: 0, left: 8 }}
      >
        <CartesianGrid strokeDasharray="3 3" horizontal={false} stroke="#f3f4f6" />
        <XAxis
          type="number"
          tick={{ fontSize: 11, fill: '#6b7280' }}
          allowDecimals={false}
        />
        <YAxis
          dataKey="label"
          type="category"
          tick={{ fontSize: 11, fill: '#6b7280' }}
          width={120}
        />
        <Tooltip
          formatter={(value, name) => [
            value,
            name === 'ok'
              ? t('email_logs.stats.ok_emails', 'Correctes')
              : t('email_logs.stats.error_emails', 'Errors'),
          ]}
        />
        <Legend
          iconSize={8}
          wrapperStyle={{ fontSize: '11px' }}
          formatter={(value) =>
            value === 'ok'
              ? t('email_logs.stats.ok_emails', 'Correctes')
              : t('email_logs.stats.error_emails', 'Errors')
          }
        />
        <Bar dataKey="ok" stackId="t" fill="#10b981" name="ok" />
        <Bar dataKey="errors" stackId="t" fill="#ef4444" name="errors" />
      </BarChart>
    </ResponsiveContainer>
  )
}
