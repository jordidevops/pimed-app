import { formatTimesheetMinutes } from './timesheetService'
import type { MonthlyCloseIssue } from './monthlyCloseValidationService'

export function formatMonthlyCloseIssue(
  issue: MonthlyCloseIssue,
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string,
): string {
  const dates =
    issue.work_dates?.length
      ? issue.work_dates.slice(0, 3).join(', ') +
        (issue.work_dates.length > 3 ? '…' : '')
      : issue.work_date ?? ''

  switch (issue.code) {
    case 'PERIOD_NOT_ENDED':
      return t(
        'monthly_close.blocker.PERIOD_NOT_ENDED',
        'El període encara no ha acabat (només es pot confirmar després del {{period_to}})',
        { period_to: issue.period_to ?? '' },
      )
    case 'FUTURE_MONTH':
      return t('monthly_close.blocker.FUTURE_MONTH', 'El mes encara no ha passat')
    case 'CURRENT_MONTH_INCOMPLETE':
      return t(
        'monthly_close.blocker.CURRENT_MONTH_INCOMPLETE',
        'El mes encara té dies laborables pendents',
      )
    case 'OPEN_TIME_ENTRY':
      return (
        t('monthly_close.blocker.OPEN_TIME_ENTRY', '{{count}} jornada(es) oberta(es)', {
          count: issue.count ?? 0,
        }) + (dates ? ` (${dates})` : '')
      )
    case 'NEEDS_REVIEW':
      return (
        t('monthly_close.blocker.NEEDS_REVIEW', '{{count}} dia(es) amb revisió pendent', {
          count: issue.count ?? 0,
        }) + (dates ? ` (${dates})` : '')
      )
    case 'MISSING_WORKDAY_RECORD':
      return (
        t(
          'monthly_close.blocker.MISSING_WORKDAY_RECORD',
          '{{count}} dia(es) laborable(s) sense registre ni absència',
          { count: issue.count ?? 0 },
        ) + (dates ? ` (${dates})` : '')
      )
    case 'DRAFT_DAYS':
      return t('monthly_close.warning.DRAFT_DAYS', '{{count}} dia(es) sense aprovar', {
        count: issue.count ?? 0,
      })
    case 'ANOMALY_DAYS':
      return t('monthly_close.warning.ANOMALY_DAYS', '{{count}} dia(es) amb anomalies', {
        count: issue.count ?? 0,
      })
    case 'WORKED_EXPECTED_DIFF':
      return t(
        'monthly_close.warning.WORKED_EXPECTED_DIFF',
        'Diferència treballat vs previst: {{diff}} (llindar {{threshold}})',
        {
          diff: formatTimesheetMinutes(issue.difference_minutes ?? 0),
          threshold: formatTimesheetMinutes(issue.threshold_minutes ?? 0),
        },
      )
    case 'EMPLOYEE_CONFIRM_VIA_SIGNATURE':
      return t(
        'monthly_close.blocker.EMPLOYEE_CONFIRM_VIA_SIGNATURE',
        'La confirmació de l’empleat es fa signant el registre mensual després del tancament per nòmina.',
      )
    case 'EMPLOYEE_PERIOD_CONFIRM_INCOMPLETE':
      if (issue.cycle === 'iso_week') {
        return t(
          'monthly_close.blocker.EMPLOYEE_PERIOD_CONFIRM_INCOMPLETE_WEEKS',
          "L'empleat ha de confirmar totes les setmanes del mes ({{confirmed}}/{{required}})",
          {
            confirmed: issue.weeks_confirmed ?? 0,
            required: issue.weeks_required ?? 0,
          },
        )
      }
      return t(
        'monthly_close.blocker.EMPLOYEE_PERIOD_CONFIRM_INCOMPLETE',
        "L'empleat ha de confirmar el registre del mes abans del tancament",
      )
    default:
      return issue.code
  }
}
