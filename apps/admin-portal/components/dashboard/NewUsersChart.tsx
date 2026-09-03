'use client'

import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from 'recharts'
import type { NewUserDay } from '@/app/admin/actions/analytics'

interface Props {
  data: NewUserDay[]
}

function fmtDayLabel(iso: string): string {
  const [year, month, day] = iso.split('-').map(Number)
  return new Date(year, month - 1, day).toLocaleDateString('ca-ES', {
    day: 'numeric',
    month: 'short',
  })
}

function fmtDayTooltip(iso: string): string {
  const [year, month, day] = iso.split('-').map(Number)
  return new Date(year, month - 1, day).toLocaleDateString('ca-ES', {
    weekday: 'short',
    day: 'numeric',
    month: 'long',
  })
}

export function NewUsersChart({ data }: Props) {
  const hasData = data.some((d) => d.count > 0)

  // Show every 7th label to avoid crowding on the 30-day axis
  const chartData = data.map((d, i) => ({
    ...d,
    label: i % 7 === 0 || i === data.length - 1 ? fmtDayLabel(d.day) : '',
  }))

  return (
    <div className="bg-white rounded-2xl border border-gray-100 shadow-sm p-5">
      <h2 className="text-sm font-semibold text-gray-700 mb-4">
        Nous usuaris per dia — últims 30 dies
      </h2>

      {!hasData ? (
        <div className="h-40 flex items-center justify-center text-sm text-gray-400">
          Sense dades de primer accés en els últims 30 dies
        </div>
      ) : (
        <ResponsiveContainer width="100%" height={200}>
          <BarChart
            data={chartData}
            margin={{ top: 4, right: 8, left: -20, bottom: 0 }}
            barCategoryGap="30%"
          >
            <CartesianGrid vertical={false} strokeDasharray="3 3" stroke="#f0f0f0" />
            <XAxis
              dataKey="label"
              tick={{ fontSize: 11, fill: '#9ca3af' }}
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
                const item = payload[0].payload as NewUserDay
                return (
                  <div className="bg-white border border-gray-200 rounded-xl shadow-md px-3 py-2 text-xs">
                    <p className="text-gray-500 mb-1">{fmtDayTooltip(item.day)}</p>
                    <p className="font-semibold text-indigo-600">
                      {item.count} {item.count === 1 ? 'usuari nou' : 'usuaris nous'}
                    </p>
                  </div>
                )
              }}
            />
            <Bar dataKey="count" fill="#6366f1" radius={[4, 4, 0, 0]} maxBarSize={24} />
          </BarChart>
        </ResponsiveContainer>
      )}
    </div>
  )
}
