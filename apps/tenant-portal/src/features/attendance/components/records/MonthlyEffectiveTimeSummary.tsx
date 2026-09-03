import { useTranslation } from 'react-i18next'
import { formatTimesheetMinutes } from '../../api/timesheetService'
import { isMobileWorkProfileSnapshot } from '../../utils/effectiveTimeDayUtils'

export interface MonthlyEffectiveSummary {
  worked_minutes?: number
  expected_minutes?: number
  difference_minutes?: number
  presence_minutes?: number | null
  effective_minutes?: number | null
  paid_minutes?: number | null
  travel_minutes?: number | null
  overtime_minutes?: number | null
  overtime_authorized_minutes?: number | null
  has_effective_time?: boolean
  work_profile_snapshot?: string | null
}

export function hasMonthlyEffectiveTime(summary: MonthlyEffectiveSummary | null | undefined): boolean {
  if (!summary) return false
  if (summary.has_effective_time === true) return true
  if (summary.has_effective_time === false) return false
  // Compat API antiga: només mostrar si hi ha dades reals (no DEFAULT 0)
  return (
    (summary.effective_minutes ?? 0) > 0 ||
    (summary.paid_minutes ?? 0) > 0 ||
    (summary.presence_minutes ?? 0) > 0
  )
}

function SummaryCell({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border bg-muted/20 p-3 text-center">
      <p className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
        {label}
      </p>
      <p className="mt-1 text-lg font-semibold tabular-nums">{value}</p>
    </div>
  )
}

interface MonthlyEffectiveTimeSummaryProps {
  summary: MonthlyEffectiveSummary
  /** Perfil dominant del mes (opcional). */
  workProfile?: string | null
  className?: string
}

export function MonthlyEffectiveTimeSummary({
  summary,
  workProfile,
  className = '',
}: MonthlyEffectiveTimeSummaryProps) {
  const { t } = useTranslation('attendance')

  if (!hasMonthlyEffectiveTime(summary)) return null

  const mobile = isMobileWorkProfileSnapshot(workProfile ?? null)
  const showPaid =
    summary.paid_minutes != null &&
    (mobile || summary.effective_minutes == null || summary.paid_minutes !== summary.effective_minutes)

  const col2Label = mobile
    ? t('monthly_report.col_presence', 'Presència')
    : t('monthly_report.col_net', 'Treball net')

  const col2Value = mobile
    ? formatTimesheetMinutes(summary.presence_minutes ?? 0)
    : formatTimesheetMinutes(summary.worked_minutes ?? 0)

  const gridCols = showPaid ? 'grid-cols-2 sm:grid-cols-4' : 'grid-cols-2 sm:grid-cols-3'

  return (
    <section className={`space-y-2 ${className}`}>
      <h4 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
        {t('monthly_report.effective_summary_title', 'Temps efectiu del mes')}
      </h4>
      <div className={`grid gap-3 ${gridCols}`}>
        <SummaryCell
          label={t('monthly_report.col_planned', 'Planificat')}
          value={formatTimesheetMinutes(summary.expected_minutes ?? 0)}
        />
        <SummaryCell label={col2Label} value={col2Value} />
        <SummaryCell
          label={t('monthly_report.col_effective', 'Efectiu')}
          value={formatTimesheetMinutes(summary.effective_minutes ?? 0)}
        />
        {showPaid && (
          <SummaryCell
            label={t('monthly_report.col_paid', 'Remunerable')}
            value={formatTimesheetMinutes(summary.paid_minutes ?? 0)}
          />
        )}
      </div>
      {(summary.travel_minutes ?? 0) > 0 && (
        <p className="text-xs text-muted-foreground">
          {t('monthly_report.travel_total', {
            value: formatTimesheetMinutes(summary.travel_minutes ?? 0),
            defaultValue: 'Desplaçament total: {{value}}',
          })}
        </p>
      )}
    </section>
  )
}

/** Text L1 per confirmació mensual segons disponibilitat de buckets. */
export function monthlyConfirmAckText(
  summary: MonthlyEffectiveSummary | null | undefined,
  t: (key: string, fallback: string) => string,
): string {
  if (hasMonthlyEffectiveTime(summary)) {
    return t(
      'monthly_employee.confirm_ack_effective',
      'He revisat el temps remunerable, el temps efectiu i les hores extra del mes i confirmo que el registre és correcte.',
    )
  }
  return t(
    'monthly_employee.confirm_ack',
    'He revisat les hores del mes i confirmo que el registre és correcte.',
  )
}
