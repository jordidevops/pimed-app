import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { CheckCircle2, CircleDashed } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import type { MonthPeriodStatus } from '../../api/periodConfirmService'
import {
  formatPeriodRangeDisplay,
  isPeriodConfirmed,
  listIsoWeeksInMonth,
} from '../../utils/periodConfirmUtils'

interface PeriodConfirmStatusPanelProps {
  periodStatus: MonthPeriodStatus
  year: number
  month: number
}

export function PeriodConfirmStatusPanel({
  periodStatus,
  year,
  month,
}: PeriodConfirmStatusPanelProps) {
  const { t } = useTranslation('attendance')

  const periods = useMemo(() => {
    if (periodStatus.cycle === 'iso_week') {
      return listIsoWeeksInMonth(year, month).map((week) => ({
        from: week.from,
        to: week.to,
        confirmed: isPeriodConfirmed(periodStatus.confirmations, week.from, week.to),
      }))
    }

    return [
      {
        from: periodStatus.month_from,
        to: periodStatus.month_to,
        confirmed: periodStatus.month_period_confirmed,
      },
    ]
  }, [month, periodStatus, year])

  const pendingCount = periods.filter((p) => !p.confirmed).length

  return (
    <div className="space-y-2 rounded-lg border bg-muted/15 p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-medium">
          {t('period_confirm.manager_title', 'Confirmacions de l’empleat')}
        </p>
        {periodStatus.cycle === 'iso_week' ? (
          <p className="text-xs text-muted-foreground">
            {t('period_confirm.weeks_progress', '{{confirmed}}/{{required}} setmanes confirmades', {
              confirmed: periodStatus.weeks_confirmed,
              required: periodStatus.weeks_required,
            })}
          </p>
        ) : (
          <p className="text-xs text-muted-foreground">
            {periodStatus.month_fully_confirmed
              ? t('period_confirm.month_done', 'Mes confirmat per l’empleat')
              : t('period_confirm.month_pending', 'Mes pendent de confirmació')}
          </p>
        )}
      </div>

      <ul className="space-y-1.5">
        {periods.map((period) => (
          <li
            key={`${period.from}-${period.to}`}
            className="flex items-center justify-between gap-2 rounded-md border bg-background px-2.5 py-1.5 text-sm"
          >
            <span className="text-muted-foreground">
              {formatPeriodRangeDisplay(period.from, period.to)}
            </span>
            {period.confirmed ? (
              <Badge variant="outline" className="gap-1 border-emerald-200 bg-emerald-50 text-emerald-800">
                <CheckCircle2 className="h-3 w-3" />
                {t('period_confirm.status_confirmed', 'Confirmat')}
              </Badge>
            ) : (
              <Badge variant="outline" className="gap-1 border-amber-200 bg-amber-50 text-amber-900">
                <CircleDashed className="h-3 w-3" />
                {t('period_confirm.status_pending', 'Pendent')}
              </Badge>
            )}
          </li>
        ))}
      </ul>

      {pendingCount > 0 && (
        <p className="text-xs text-muted-foreground">
          {t('period_confirm.manager_pending_hint', {
            count: pendingCount,
            defaultValue:
              '{{count}} període(s) encara sense confirmar. El tancament pot estar bloquejat segons la configuració.',
          })}
        </p>
      )}
    </div>
  )
}
