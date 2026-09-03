'use client'

import {
  PieChart,
  Pie,
  Cell,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from 'recharts'

// Color palette per plan name (slug-based), with fallback rotation
const PLAN_COLORS: Record<string, string> = {
  free:       '#94a3b8',
  pro:        '#6366f1',
  enterprise: '#f59e0b',
  starter:    '#22c55e',
}
const FALLBACK_COLORS = ['#6366f1', '#f59e0b', '#22c55e', '#ec4899', '#14b8a6']

export interface PlanSlice {
  name: string
  display_name: string
  count: number
  mrr: number
}

export function PlanDistributionChart({ data }: { data: PlanSlice[] }) {
  if (data.length === 0) return null

  return (
    <ResponsiveContainer width="100%" height={240}>
      <PieChart>
        <Pie
          data={data}
          dataKey="count"
          nameKey="display_name"
          cx="50%"
          cy="50%"
          outerRadius={88}
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          label={(props: any) => `${props.display_name} (${props.count})`}
          labelLine={false}
        >
          {data.map((entry, idx) => (
            <Cell
              key={entry.name}
              fill={PLAN_COLORS[entry.name] ?? FALLBACK_COLORS[idx % FALLBACK_COLORS.length]}
            />
          ))}
        </Pie>
        <Tooltip
          formatter={(value, _name, item) => [
            `${value} tenants · €${((item.payload as PlanSlice)?.mrr ?? 0).toFixed(0)}/mes`,
          ]}
        />
        <Legend />
      </PieChart>
    </ResponsiveContainer>
  )
}
