import { useTranslation } from 'react-i18next'
import { CalendarOff, Stethoscope } from 'lucide-react'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { cn } from '@/lib/utils'
import type { AbsenceTypeConfig } from '../../api/shiftsService'
import type { PayrollReviewDay } from '../../api/payrollReviewService'
import { absenceTypeLabel } from './absenceUiUtils'

interface TimesheetDayAbsenceIndicatorProps {
  payrollDay: PayrollReviewDay
  typeConfigMap: Record<string, AbsenceTypeConfig>
  lang: string
  className?: string
}

export function TimesheetDayAbsenceIndicator({
  payrollDay,
  typeConfigMap,
  lang,
  className,
}: TimesheetDayAbsenceIndicatorProps) {
  const { t } = useTranslation('attendance')

  if (!payrollDay.absence_id) return null

  const isIt = payrollDay.is_it
  const cfg = payrollDay.absence_type ? typeConfigMap[payrollDay.absence_type] : undefined
  const typeLabel = absenceTypeLabel(cfg, payrollDay.absence_type ?? '', lang)
  const status = payrollDay.absence_status ?? 'approved'
  const Icon = isIt ? Stethoscope : CalendarOff

  const partial =
    payrollDay.partial_start_time && payrollDay.partial_end_time
      ? `${payrollDay.partial_start_time.slice(0, 5)} – ${payrollDay.partial_end_time.slice(0, 5)}`
      : null

  return (
    <Popover>
      <PopoverTrigger asChild>
        <button
          type="button"
          className={cn(
            'ml-1.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-md transition-colors',
            isIt
              ? 'text-violet-700 hover:bg-violet-100'
              : 'text-sky-700 hover:bg-sky-100',
            className,
          )}
          title={t('timesheet.absence_info', 'Veure absència')}
          onClick={(e) => e.stopPropagation()}
        >
          <Icon className="h-3.5 w-3.5" aria-hidden />
          <span className="sr-only">{t('timesheet.absence_info', 'Veure absència')}</span>
        </button>
      </PopoverTrigger>
      <PopoverContent className="w-64 space-y-2 text-sm" align="start" onClick={(e) => e.stopPropagation()}>
        <p className="font-medium">
          {isIt
            ? t('payroll_review.absence_it', 'Baixa mèdica / IT')
            : t('payroll_review.absence_badge', 'Absència')}
        </p>
        <p>{typeLabel}</p>
        <p className="text-xs text-muted-foreground">
          {t('absences.status_label', 'Estat')}: {t(`absences.status.${status}`, status)}
        </p>
        {partial ? (
          <p className="text-xs text-muted-foreground">
            {t('absences.partial', 'Parcial')}: {partial}
          </p>
        ) : null}
        {cfg?.counts_as_worked != null && (
          <p className="text-xs text-muted-foreground">
            {cfg.counts_as_worked
              ? t('absences.form.counts_as_work', 'Compta com a temps treballat')
              : t('absences.form.not_counts_as_work', 'No compta com a temps treballat')}
          </p>
        )}
      </PopoverContent>
    </Popover>
  )
}
