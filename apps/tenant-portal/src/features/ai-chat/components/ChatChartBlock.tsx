import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Legend,
  Line,
  LineChart,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import type { ChartUiBlock } from '@/features/ai-chat/schemas/chartBlock'

const CHART_COLORS = ['#6366f1', '#22c55e', '#f59e0b', '#ef4444', '#8b5cf6', '#06b6d4']

function buildSeriesData(block: ChartUiBlock) {
  return block.labels.map((label, index) => {
    const row: Record<string, string | number> = { label }
    for (const dataset of block.datasets) {
      row[dataset.label] = dataset.values[index] ?? 0
    }
    return row
  })
}

function buildPieData(block: ChartUiBlock) {
  const primary = block.datasets[0]
  return block.labels.map((label, index) => ({
    name: label,
    value: primary?.values[index] ?? 0,
  }))
}

type ChatChartBlockProps = {
  chart: ChartUiBlock
}

export function ChatChartBlock({ chart }: ChatChartBlockProps) {
  const seriesKeys = chart.datasets.map((dataset) => dataset.label)

  return (
    <div className="rounded-lg border bg-background p-3">
      <h3 className="text-sm font-semibold mb-2">{chart.title}</h3>
      <div className="h-56 w-full">
        <ResponsiveContainer width="100%" height="100%">
          {chart.chartType === 'pie' ? (
            <PieChart>
              <Pie
                data={buildPieData(chart)}
                dataKey="value"
                nameKey="name"
                cx="50%"
                cy="50%"
                outerRadius={80}
                label={({ name, percent }) =>
                  `${name} (${((percent ?? 0) * 100).toFixed(0)}%)`
                }
              >
                {buildPieData(chart).map((_, index) => (
                  <Cell key={index} fill={CHART_COLORS[index % CHART_COLORS.length]} />
                ))}
              </Pie>
              <Tooltip />
              <Legend />
            </PieChart>
          ) : chart.chartType === 'line' ? (
            <LineChart data={buildSeriesData(chart)} margin={{ top: 4, right: 8, left: -16, bottom: 0 }}>
              <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
              <XAxis dataKey="label" tick={{ fontSize: 11 }} />
              <YAxis tick={{ fontSize: 11 }} />
              <Tooltip />
              <Legend />
              {seriesKeys.map((key, index) => (
                <Line
                  key={key}
                  type="monotone"
                  dataKey={key}
                  stroke={CHART_COLORS[index % CHART_COLORS.length]}
                  strokeWidth={2}
                  dot={{ r: 3 }}
                />
              ))}
            </LineChart>
          ) : (
            <BarChart data={buildSeriesData(chart)} margin={{ top: 4, right: 8, left: -16, bottom: 0 }}>
              <CartesianGrid strokeDasharray="3 3" className="stroke-border" />
              <XAxis dataKey="label" tick={{ fontSize: 11 }} />
              <YAxis tick={{ fontSize: 11 }} />
              <Tooltip />
              <Legend />
              {seriesKeys.map((key, index) => (
                <Bar
                  key={key}
                  dataKey={key}
                  fill={CHART_COLORS[index % CHART_COLORS.length]}
                  radius={[4, 4, 0, 0]}
                />
              ))}
            </BarChart>
          )}
        </ResponsiveContainer>
      </div>
    </div>
  )
}
