import { useTranslation } from 'react-i18next'
import { RefreshCw } from 'lucide-react'
import { useEmailUsage } from '../api/useEmailUsage'

interface QuotaCardProps {
  tenantId: string
  rateLimitPerHour: number
  rateLimitPerDay: number
  maxRetries: number
  retentionDays: number
}

function UsageBar({
  label,
  used,
  limit,
}: {
  label: string
  used: number
  limit: number
}) {
  const pct = limit > 0 ? Math.min(100, Math.round((used / limit) * 100)) : 0
  const barColor =
    pct >= 90
      ? 'bg-red-500'
      : pct >= 70
        ? 'bg-amber-400'
        : 'bg-blue-500'

  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between text-xs">
        <span className="text-blue-700 font-medium">{label}</span>
        <span className="text-blue-800 font-semibold tabular-nums">
          {used.toLocaleString()} / {limit.toLocaleString()}
        </span>
      </div>
      <div className="h-2 w-full rounded-full bg-blue-100 overflow-hidden">
        <div
          className={`h-full rounded-full transition-all duration-500 ${barColor}`}
          style={{ width: `${pct}%` }}
          role="progressbar"
          aria-valuenow={used}
          aria-valuemin={0}
          aria-valuemax={limit}
        />
      </div>
      <p className="text-[11px] text-blue-500 text-right">{pct}%</p>
    </div>
  )
}

export function QuotaCard({
  tenantId,
  rateLimitPerHour,
  rateLimitPerDay,
  maxRetries,
  retentionDays,
}: QuotaCardProps) {
  const { t } = useTranslation('email')
  const { data: usage, isLoading, refetch, isFetching } = useEmailUsage(tenantId)

  return (
    <div className="rounded-lg border border-blue-200 bg-blue-50 p-5 space-y-4">
      {/* Capçalera */}
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-blue-900">
          {t('email.config.quota_title', 'Límits de quota actuals')}
        </h3>
        <button
          type="button"
          onClick={() => refetch()}
          disabled={isFetching}
          className="inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-xs font-medium text-blue-700 hover:bg-blue-100 disabled:opacity-50 transition-colors"
          aria-label={t('email.config.quota_refresh', 'Actualitzar consums')}
        >
          <RefreshCw className={`size-3.5 ${isFetching ? 'animate-spin' : ''}`} />
          {t('email.config.quota_refresh', 'Actualitzar')}
        </button>
      </div>

      {/* Barres de consum */}
      {isLoading ? (
        <div className="space-y-3 animate-pulse">
          <div className="h-2 bg-blue-200 rounded-full w-full" />
          <div className="h-2 bg-blue-200 rounded-full w-full" />
        </div>
      ) : usage ? (
        <div className="space-y-3">
          <UsageBar
            label={t('email.config.usage_hour', 'Enviats darrera hora')}
            used={usage.sent_hour}
            limit={rateLimitPerHour}
          />
          <UsageBar
            label={t('email.config.usage_day', 'Enviats avui')}
            used={usage.sent_day}
            limit={rateLimitPerDay}
          />
        </div>
      ) : null}

      {/* Metadades de quota (read-only) */}
      <dl className="grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-4 pt-2 border-t border-blue-100">
        <div>
          <dt className="text-xs text-blue-600 font-medium uppercase tracking-wide">
            {t('email.config.rate_per_hour', 'Límit/hora')}
          </dt>
          <dd className="mt-1 text-xl font-bold text-blue-900">
            {rateLimitPerHour.toLocaleString()}
          </dd>
        </div>
        <div>
          <dt className="text-xs text-blue-600 font-medium uppercase tracking-wide">
            {t('email.config.rate_per_day', 'Límit/dia')}
          </dt>
          <dd className="mt-1 text-xl font-bold text-blue-900">
            {rateLimitPerDay.toLocaleString()}
          </dd>
        </div>
        <div>
          <dt className="text-xs text-blue-600 font-medium uppercase tracking-wide">
            {t('email.config.max_retries', 'Reintents màx.')}
          </dt>
          <dd className="mt-1 text-xl font-bold text-blue-900">{maxRetries}</dd>
        </div>
        <div>
          <dt className="text-xs text-blue-600 font-medium uppercase tracking-wide">
            {t('email.config.retention_days', 'Retenció (dies)')}
          </dt>
          <dd className="mt-1 text-xl font-bold text-blue-900">{retentionDays}</dd>
        </div>
      </dl>
      <p className="text-xs text-blue-500">
        {t('email.config.quota_managed_by_platform', 'Els límits els gestiona la plataforma. Contacta amb suport per ampliar-los.')}
      </p>
    </div>
  )
}
