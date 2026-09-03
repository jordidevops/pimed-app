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
import type { ActivityBuckets } from '@/app/admin/actions/analytics'

interface Props {
  data: ActivityBuckets
}

const BUCKET_CONFIG = [
  { key: 'dau', label: 'Avui (DAU)',    color: '#6366f1' },
  { key: 'wau', label: 'Setmana (WAU)', color: '#818cf8' },
  { key: 'mau', label: 'Mes (MAU)',     color: '#a5b4fc' },
] as const

export function ActivityBucketsChart({ data }: Props) {
  const chartData = BUCKET_CONFIG.map(({ key, label, color }) => ({
    label,
    count: data[key],
    color,
  }))

  return (
    <div className="bg-white rounded-2xl border border-gray-100 shadow-sm p-5">
      <div className="flex items-start justify-between mb-4 gap-4">
        <h2 className="text-sm font-semibold text-gray-700">
          Usuaris actius — DAU / WAU / MAU
        </h2>
        <div className="flex-shrink-0 text-right">
          <p className="text-xs text-gray-400">
            Total amb accés:{' '}
            <span className="font-semibold text-gray-700">{data.totalActive}</span>
            {' · '}
            Pendents:{' '}
            <span className="font-semibold text-gray-700">
              {data.totalUsers - data.totalActive}
            </span>
          </p>
        </div>
      </div>

      {data.totalActive === 0 ? (
        <div className="h-40 flex items-center justify-center text-sm text-gray-400">
          Cap usuari ha accedit encara
        </div>
      ) : (
        <ResponsiveContainer width="100%" height={200}>
          <BarChart
            data={chartData}
            margin={{ top: 4, right: 8, left: -20, bottom: 0 }}
            barCategoryGap="40%"
          >
            <CartesianGrid vertical={false} strokeDasharray="3 3" stroke="#f0f0f0" />
            <XAxis
              dataKey="label"
              tick={{ fontSize: 12, fill: '#6b7280' }}
              axisLine={false}
              tickLine={false}
            />
            <YAxis
              allowDecimals={false}
              tick={{ fontSize: 11, fill: '#9ca3af' }}
              axisLine={false}
              tickLine={false}
              width={28}
            />
            <Tooltip
              content={({ active, payload }) => {
                if (!active || !payload?.length) return null
                const item = payload[0].payload as { label: string; count: number }
                return (
                  <div className="bg-white border border-gray-200 rounded-xl shadow-md px-3 py-2 text-xs">
                    <p className="text-gray-500 mb-1">{item.label}</p>
                    <p className="font-semibold text-indigo-600">
                      {item.count} {item.count === 1 ? 'usuari actiu' : 'usuaris actius'}
                    </p>
                  </div>
                )
              }}
            />
            <Bar dataKey="count" radius={[4, 4, 0, 0]} maxBarSize={60}>
              {chartData.map((entry, i) => (
                <Cell key={i} fill={entry.color} />
              ))}
            </Bar>
          </BarChart>
        </ResponsiveContainer>
      )}
    </div>
  )
}
