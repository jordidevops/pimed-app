import { useTranslation } from 'react-i18next'
import { ShieldAlert, ShieldCheck, ShieldQuestion } from 'lucide-react'
import { useEmployeeDispatchStatus } from '../api/useEmployeeDispatchStatus'

export function EmployeeReadinessBadge({
  employeeId,
  compact = false,
}: {
  employeeId: string
  /** Capçalera: una línia de status; motius només si blocked */
  compact?: boolean
}) {
  const { t } = useTranslation('employees')
  const { data, isLoading, error } = useEmployeeDispatchStatus(employeeId)

  if (isLoading) {
    return (
      <div
        className={
          compact
            ? 'rounded-md border px-2.5 py-1 text-xs text-muted-foreground'
            : 'rounded-lg border px-3 py-2 text-sm text-muted-foreground'
        }
        data-testid="employee-readiness-badge"
        data-state="loading"
      >
        {t('employees.readiness.loading', 'Comprovant readiness…')}
      </div>
    )
  }

  if (error || !data) {
    return null
  }

  const Icon =
    data.configuration_status === 'unconfigured' && data.is_eligible
      ? ShieldQuestion
      : data.is_eligible
        ? ShieldCheck
        : ShieldAlert

  const tone =
    data.configuration_status === 'unconfigured' && data.is_eligible
      ? 'border-muted bg-muted/30 text-muted-foreground'
      : data.is_eligible
        ? 'border-emerald-200 bg-emerald-50 text-emerald-800'
        : 'border-amber-200 bg-amber-50 text-amber-900'

  const formatReason = (reason: string) =>
    reason
      .replace(/^MISSING_OR_EXPIRED:/, t('employees.readiness.reason_missing_cert', 'Falta o caducat: '))
      .replace(/^MISSING_REQUIRED_CONTEXT:/, t('employees.readiness.reason_missing_context', 'Falta context: '))
      .replace(/^MISSING_ASSET:/, t('employees.readiness.reason_missing_asset', 'Falta actiu: '))
      .replace(/^LIFECYCLE_STATE_/, t('employees.readiness.reason_lifecycle', 'Estat lifecycle: '))

  const label = data.is_eligible
    ? data.configuration_status === 'unconfigured'
      ? t('employees.readiness.unconfigured', 'Readiness no configurat')
      : t('employees.readiness.eligible', 'Eligible per operar')
    : t('employees.readiness.not_eligible', 'No eligible per operar')

  const showReasons = !data.is_eligible && data.blocking_reasons.length > 0
  const showPartial = data.configuration_status === 'partial'

  return (
    <div
      className={`rounded-md border ${compact ? 'px-2.5 py-1.5 max-w-sm' : 'rounded-lg px-3 py-2'} space-y-1 ${tone}`}
      data-testid="employee-readiness-badge"
      data-eligible={data.is_eligible ? 'true' : 'false'}
      data-config={data.configuration_status}
    >
      <div className={`flex items-center gap-1.5 font-medium ${compact ? 'text-xs' : 'text-sm'}`}>
        <Icon className={compact ? 'h-3.5 w-3.5 shrink-0' : 'h-4 w-4 shrink-0'} aria-hidden />
        <span className="truncate">{label}</span>
      </div>
      {showPartial ? (
        <p className="text-xs opacity-80 leading-snug">
          {t(
            'employees.readiness.partial_hint',
            "Hi ha regles d'àmbit (dept/posició/site) però l'empleat no té aquest àmbit resolt.",
          )}
        </p>
      ) : null}
      {showReasons ? (
        <ul
          className={`list-disc pl-4 space-y-0.5 opacity-90 ${compact ? 'text-[11px] leading-snug' : 'text-xs'}`}
          data-testid="employee-readiness-reasons"
        >
          {(compact ? data.blocking_reasons.slice(0, 2) : data.blocking_reasons).map((reason) => (
            <li key={reason}>{formatReason(reason)}</li>
          ))}
          {compact && data.blocking_reasons.length > 2 ? (
            <li className="list-none -ml-4 text-muted-foreground">
              {t('employees.readiness.more_reasons', '+{{count}} més', {
                count: data.blocking_reasons.length - 2,
              })}
            </li>
          ) : null}
        </ul>
      ) : null}
    </div>
  )
}
