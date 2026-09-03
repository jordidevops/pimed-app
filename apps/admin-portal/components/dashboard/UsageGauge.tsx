interface UsageGaugeProps {
  label: string
  usedBytes: bigint | number
  quotaBytes: bigint | number
  warningThreshold?: number  // 0–1, default 0.8
  dangerThreshold?: number   // 0–1, default 0.95
  unit?: 'bytes' | 'custom'
  formatValue?: (bytes: number) => string
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`
  return `${(bytes / 1024 ** 3).toFixed(2)} GB`
}

export function UsageGauge({
  label,
  usedBytes,
  quotaBytes,
  warningThreshold = 0.8,
  dangerThreshold = 0.95,
  formatValue = formatBytes,
}: UsageGaugeProps) {
  const used = Number(usedBytes)
  const quota = Number(quotaBytes)
  const ratio = quota > 0 ? Math.min(used / quota, 1) : 0
  const pct = Math.round(ratio * 100)

  const barColor =
    ratio >= dangerThreshold
      ? 'bg-red-500'
      : ratio >= warningThreshold
      ? 'bg-amber-400'
      : 'bg-indigo-500'

  const textColor =
    ratio >= dangerThreshold
      ? 'text-red-600'
      : ratio >= warningThreshold
      ? 'text-amber-600'
      : 'text-gray-700'

  return (
    <div className="space-y-1.5">
      <div className="flex items-center justify-between text-sm">
        <span className="font-medium text-gray-700">{label}</span>
        <span className={`font-semibold tabular-nums ${textColor}`}>
          {quota > 0 ? `${pct}%` : '—'}
        </span>
      </div>

      {/* Track */}
      <div className="h-2.5 w-full rounded-full bg-gray-100 overflow-hidden">
        <div
          className={`h-full rounded-full transition-all duration-300 ${barColor}`}
          style={{ width: `${pct}%` }}
        />
      </div>

      <div className="flex items-center justify-between text-xs text-gray-400">
        <span>{formatValue(used)}</span>
        <span>{quota > 0 ? `de ${formatValue(quota)}` : 'sense límit'}</span>
      </div>
    </div>
  )
}
