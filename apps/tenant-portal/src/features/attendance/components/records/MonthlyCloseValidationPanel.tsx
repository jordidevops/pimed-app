import { useTranslation } from 'react-i18next'
import { AlertCircle, AlertTriangle, Loader2 } from 'lucide-react'
import { formatMonthlyCloseIssue } from '../../api/monthlyCloseIssueLabels'
import { useMonthlyCloseValidation } from '../../api/useMonthlyCloseValidation'
import { useMonthlyEmployeeConfirmValidation } from '../../api/useMonthlyEmployeeConfirmValidation'

interface MonthlyCloseValidationPanelProps {
  employeeId: string
  year: number
  month: number
  variant: 'employee' | 'manager'
  enabled?: boolean
}

export function MonthlyCloseValidationPanel({
  employeeId,
  year,
  month,
  variant,
  enabled = true,
}: MonthlyCloseValidationPanelProps) {
  const { t } = useTranslation('attendance')
  const { data, isLoading, error } = useMonthlyCloseValidation(
    employeeId,
    year,
    month,
    variant === 'manager',
  )
  const {
    data: confirmData,
    isLoading: confirmLoading,
    error: confirmError,
  } = useMonthlyEmployeeConfirmValidation(
    employeeId,
    year,
    month,
    variant === 'employee' && enabled,
  )

  if (!enabled) return null

  if (variant === 'employee') {
    if (confirmLoading) {
      return (
        <div className="flex items-center gap-2 rounded-lg border bg-muted/20 px-3 py-2 text-xs text-muted-foreground">
          <Loader2 className="h-3.5 w-3.5 animate-spin" />
          {t('monthly_employee.confirm_loading', 'Comprovant si pots confirmar el registre…')}
        </div>
      )
    }

    if (confirmError || !confirmData) return null

    if (confirmData.confirmable) {
      return (
        <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs text-emerald-900">
          {t('monthly_employee.confirm_ready', 'Pots confirmar el registre del mes.')}
        </div>
      )
    }

    if (confirmData.blockers.length === 0) return null

    return (
      <div className="space-y-2 rounded-lg border bg-muted/20 px-3 py-3 text-sm">
        <div className="space-y-1">
          <p className="flex items-center gap-1.5 text-xs font-semibold text-destructive">
            <AlertCircle className="h-3.5 w-3.5 shrink-0" />
            {t('monthly_employee.confirm_blockers_title', 'No es pot confirmar encara')}
          </p>
          <ul className="list-disc space-y-0.5 pl-5 text-xs text-destructive/90">
            {confirmData.blockers.map((issue, i) => (
              <li key={`${issue.code}-${i}`}>{formatMonthlyCloseIssue(issue, t)}</li>
            ))}
          </ul>
        </div>
      </div>
    )
  }

  if (isLoading) {
    return (
      <div className="flex items-center gap-2 rounded-lg border bg-muted/20 px-3 py-2 text-xs text-muted-foreground">
        <Loader2 className="h-3.5 w-3.5 animate-spin" />
        {t('monthly_close.loading', 'Comprovant si el mes es pot tancar…')}
      </div>
    )
  }

  if (error || !data) return null

  const hasBlockers = data.blockers.length > 0
  const hasWarnings = data.warnings.length > 0

  if (!hasBlockers && !hasWarnings) {
    return (
      <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs text-emerald-900">
        {t('monthly_close.ready', 'El mes es pot tancar per nòmina (sense bloquejos).')}
      </div>
    )
  }

  return (
    <div className="space-y-2 rounded-lg border bg-muted/20 px-3 py-3 text-sm">
      {hasBlockers && (
        <div className="space-y-1">
          <p className="flex items-center gap-1.5 text-xs font-semibold text-destructive">
            <AlertCircle className="h-3.5 w-3.5 shrink-0" />
            {t('monthly_close.blockers_title', 'Bloquejos per tancar el mes')}
          </p>
          <ul className="list-disc space-y-0.5 pl-5 text-xs text-destructive/90">
            {data.blockers.map((issue, i) => (
              <li key={`${issue.code}-${i}`}>{formatMonthlyCloseIssue(issue, t)}</li>
            ))}
          </ul>
        </div>
      )}
      {hasWarnings && (
        <div className="space-y-1">
          <p className="flex items-center gap-1.5 text-xs font-semibold text-amber-800">
            <AlertTriangle className="h-3.5 w-3.5 shrink-0" />
            {t('monthly_close.warnings_title', 'Avisos (es pot tancar amb precaució)')}
          </p>
          <ul className="list-disc space-y-0.5 pl-5 text-xs text-amber-900/90">
            {data.warnings.map((issue, i) => (
              <li key={`${issue.code}-${i}`}>{formatMonthlyCloseIssue(issue, t)}</li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
