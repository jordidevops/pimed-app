import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useMonthPeriodStatus } from '../../api/useMonthPeriodStatus'
import { usePeriodEmployeeConfirmValidation } from '../../api/usePeriodEmployeeConfirmValidation'
import { useConfirmAttendancePeriod } from '../../api/useMonthlyReportActions'
import { PeriodEmployeeConfirmDialog } from './PeriodEmployeeConfirmDialog'
import { formatTimesheetMinutes } from '../../api/timesheetService'
import { listIsoWeeksInMonth } from '../../utils/periodConfirmUtils'
import type { PayrollReviewDay } from '../../api/payrollReviewService'

function summarizePayrollDays(days: PayrollReviewDay[]) {
  const worked = days.reduce((sum, d) => sum + (d.worked_minutes > 0 ? d.worked_minutes : 0), 0)
  const expected = days.reduce((sum, d) => sum + (d.expected_minutes ?? 0), 0)
  const effective = days.reduce((sum, d) => sum + (d.effective_minutes ?? 0), 0)
  const paid = days.reduce((sum, d) => sum + (d.paid_minutes ?? 0), 0)
  const hasEffective = days.some((d) => (d.effective_minutes ?? 0) > 0 || (d.paid_minutes ?? 0) > 0)
  return {
    worked_minutes: worked,
    expected_minutes: expected,
    difference_minutes: worked - expected,
    effective_minutes: hasEffective ? effective : undefined,
    paid_minutes: hasEffective ? paid : undefined,
    has_effective_time: hasEffective,
  }
}

interface PeriodWeeklyConfirmSectionProps {
  employeeId: string
  year: number
  month: number
  payrollDays: PayrollReviewDay[]
}

export function PeriodWeeklyConfirmSection({
  employeeId,
  year,
  month,
  payrollDays,
}: PeriodWeeklyConfirmSectionProps) {
  const { t } = useTranslation('attendance')
  const weeks = useMemo(() => listIsoWeeksInMonth(year, month), [year, month])
  const [weekIndex, setWeekIndex] = useState(Math.max(0, weeks.length - 1))
  const [dialogOpen, setDialogOpen] = useState(false)
  const activeWeek = weeks[weekIndex] ?? weeks[0]

  const { data: periodStatus } = useMonthPeriodStatus(employeeId, year, month)
  const confirmMutation = useConfirmAttendancePeriod()

  const weekDays = useMemo(() => {
    if (!activeWeek) return []
    return payrollDays.filter(
      (d) => d.work_date >= activeWeek.from && d.work_date <= activeWeek.to,
    )
  }, [activeWeek, payrollDays])

  const weekSummary = useMemo(() => summarizePayrollDays(weekDays), [weekDays])

  const weekConfirmed = useMemo(() => {
    if (!activeWeek || !periodStatus) return false
    return periodStatus.confirmations.some(
      (c) => c.period_from === activeWeek.from && c.period_to === activeWeek.to,
    )
  }, [activeWeek, periodStatus])

  const { data: weekValidation, isLoading: weekValidationLoading } =
    usePeriodEmployeeConfirmValidation(
      employeeId,
      activeWeek?.from,
      activeWeek?.to,
      !!activeWeek && !weekConfirmed,
    )

  if (!activeWeek || !periodStatus || periodStatus.cycle !== 'iso_week') {
    return null
  }

  const canConfirmWeek =
    !weekConfirmed && !weekValidationLoading && (weekValidation?.confirmable ?? false)

  return (
    <div className="space-y-3 rounded-lg border bg-muted/15 p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-medium">
          {t('period_confirm.weekly_title', 'Confirmació setmanal')}
        </p>
        <p className="text-muted-foreground text-xs">
          {t('period_confirm.weeks_progress', '{{confirmed}}/{{required}} setmanes confirmades', {
            confirmed: periodStatus.weeks_confirmed,
            required: periodStatus.weeks_required,
          })}
        </p>
      </div>

      <div className="flex items-center justify-center gap-2">
        <Button
          type="button"
          variant="outline"
          size="icon"
          disabled={weekIndex <= 0}
          onClick={() => setWeekIndex((i) => Math.max(0, i - 1))}
          aria-label={t('period_confirm.prev_week', 'Setmana anterior')}
        >
          <ChevronLeft className="h-4 w-4" />
        </Button>
        <p className="min-w-[10rem] text-center text-sm font-medium tabular-nums">
          {activeWeek.from} — {activeWeek.to}
        </p>
        <Button
          type="button"
          variant="outline"
          size="icon"
          disabled={weekIndex >= weeks.length - 1}
          onClick={() => setWeekIndex((i) => Math.min(weeks.length - 1, i + 1))}
          aria-label={t('period_confirm.next_week', 'Setmana següent')}
        >
          <ChevronRight className="h-4 w-4" />
        </Button>
      </div>

      <div className="grid gap-2 text-sm sm:grid-cols-3">
        <div>
          <p className="text-xs text-muted-foreground">{t('monthly_report.worked', 'Treballat')}</p>
          <p className="font-semibold tabular-nums">{formatTimesheetMinutes(weekSummary.worked_minutes)}</p>
        </div>
        <div>
          <p className="text-xs text-muted-foreground">{t('monthly_report.expected', 'Previst')}</p>
          <p className="font-semibold tabular-nums">{formatTimesheetMinutes(weekSummary.expected_minutes)}</p>
        </div>
        <div>
          <p className="text-xs text-muted-foreground">{t('monthly_report.difference', 'Diferència')}</p>
          <p className="font-semibold tabular-nums">
            {formatTimesheetMinutes(weekSummary.difference_minutes)}
          </p>
        </div>
      </div>

      {weekConfirmed ? (
        <p className="text-sm text-emerald-800">
          {t('period_confirm.week_done', 'Aquesta setmana ja està confirmada.')}
        </p>
      ) : canConfirmWeek ? (
        <Button type="button" className="w-full" onClick={() => setDialogOpen(true)}>
          {t('period_confirm.submit', 'Confirmar aquesta setmana')}
        </Button>
      ) : (
        <p className="text-muted-foreground text-xs">
          {t(
            'period_confirm.week_blocked',
            'Encara no pots confirmar aquesta setmana (període en curs o incidències pendents).',
          )}
        </p>
      )}

      <PeriodEmployeeConfirmDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        employeeId={employeeId}
        periodFrom={activeWeek.from}
        periodTo={activeWeek.to}
        summary={{
          ...weekSummary,
          worked_days: weekDays.filter((d) => d.worked_minutes > 0).length,
          laborable_days: weekDays.filter((d) => d.is_laborable).length,
          absence_days: weekDays.filter((d) => d.absence_id).length,
          overtime_minutes: weekDays.reduce((s, d) => s + (d.overtime_minutes ?? 0), 0),
        }}
        isPending={confirmMutation.isPending}
        onConfirm={() => {
          confirmMutation.mutate(
            {
              employee_id: employeeId,
              period_from: activeWeek.from,
              period_to: activeWeek.to,
              calendar_year: year,
              calendar_month: month,
            },
            { onSuccess: () => setDialogOpen(false) },
          )
        }}
      />
    </div>
  )
}
