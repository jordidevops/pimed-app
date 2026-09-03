interface KpiCardProps {
  label: string
  value: string | number
  sub?: string
  icon: string
  highlight?: 'danger' | 'warning' | 'success'
}

export function KpiCard({ label, value, sub, icon, highlight }: KpiCardProps) {
  const borderColor =
    highlight === 'danger'
      ? 'border-red-200'
      : highlight === 'warning'
      ? 'border-amber-200'
      : highlight === 'success'
      ? 'border-green-200'
      : 'border-gray-100'

  const valueColor =
    highlight === 'danger'
      ? 'text-red-700'
      : highlight === 'warning'
      ? 'text-amber-700'
      : 'text-gray-900'

  return (
    <div className={`bg-white rounded-2xl border ${borderColor} p-5 flex items-start gap-4 shadow-sm`}>
      <span className="text-3xl leading-none">{icon}</span>
      <div>
        <p className={`text-xl font-bold leading-tight ${valueColor}`}>{value}</p>
        <p className="text-sm text-gray-500 mt-0.5">{label}</p>
        {sub && <p className="text-xs text-gray-400 mt-0.5">{sub}</p>}
      </div>
    </div>
  )
}
