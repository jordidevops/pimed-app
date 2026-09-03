import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { AlertCircle, Loader2 } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Label } from '@/components/ui/label'
import { formatTimesheetMinutes, monthDateRange } from '../../api/timesheetService'
import { monthLabel, type MonthlyReportExport } from '../../api/monthlyReportService'
import { formatMonthlyCloseIssue } from '../../api/monthlyCloseIssueLabels'
import { useMonthlyEmployeeConfirmValidation } from '../../api/useMonthlyEmployeeConfirmValidation'
import {
  MonthlyEffectiveTimeSummary,
  monthlyConfirmAckText,
} from './MonthlyEffectiveTimeSummary'

interface MonthlyEmployeeConfirmDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  employeeId: string
  year: number
  month: number
  exportData: MonthlyReportExport
  isPending: boolean
  onConfirm: () => void
}

export function MonthlyEmployeeConfirmDialog({
  open,
  onOpenChange,
  employeeId,
  year,
  month,
  exportData,
  isPending,
  onConfirm,
}: MonthlyEmployeeConfirmDialogProps) {
  const { t } = useTranslation('attendance')
  const [ackReviewed, setAckReviewed] = useState(false)
  const { from, to } = monthDateRange(year, month)

  const { data: validation, isLoading: validationLoading } = useMonthlyEmployeeConfirmValidation(
    employeeId,
    year,
    month,
    open,
  )

  const confirmable = validation?.confirmable ?? false
  const isLoading = validationLoading
  const canSubmit = ackReviewed && confirmable && !isPending && !isLoading

  function handleOpenChange(next: boolean) {
    if (!next) setAckReviewed(false)
    onOpenChange(next)
  }

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>
            {t('monthly_employee.confirm_modal_title', 'Confirmar el meu registre mensual')}
          </DialogTitle>
          <DialogDescription>
            {t('monthly_employee.confirm_modal_desc', {
              month: monthLabel(year, month),
              defaultValue:
                'Revisa el resum de {{month}} abans de confirmar. Després de confirmar, el gestor podrà tancar el mes per nòmina.',
            })}
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-3 rounded-lg bg-muted/40 p-3 text-sm sm:grid-cols-3">
          <div>
            <p className="text-xs text-muted-foreground">{t('monthly_report.worked', 'Treballat')}</p>
            <p className="font-semibold tabular-nums">
              {formatTimesheetMinutes(exportData.summary.worked_minutes)}
            </p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">{t('monthly_report.expected', 'Previst')}</p>
            <p className="font-semibold tabular-nums">
              {formatTimesheetMinutes(exportData.summary.expected_minutes)}
            </p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">{t('monthly_report.difference', 'Diferència')}</p>
            <p className="font-semibold tabular-nums">
              {formatTimesheetMinutes(exportData.summary.difference_minutes)}
            </p>
          </div>
        </div>

        <MonthlyEffectiveTimeSummary summary={exportData.summary} />

        <p className="text-xs text-muted-foreground">
          {t('monthly_close.period', 'Període')}: {from} — {to} ·{' '}
          {t('monthly_employee.days_count', '{{count}} dies amb registre', {
            count: exportData.days.length,
          })}
        </p>

        {isLoading ? (
          <div className="flex items-center gap-2 text-xs text-muted-foreground">
            <Loader2 className="h-3.5 w-3.5 animate-spin" />
            {t('monthly_employee.confirm_loading', 'Comprovant si pots confirmar el registre…')}
          </div>
        ) : null}

        {!isLoading && validation && !confirmable && validation.blockers.length > 0 ? (
          <div className="space-y-1 rounded-lg border border-destructive/30 bg-destructive/5 p-3">
            <p className="flex items-center gap-1.5 text-xs font-semibold text-destructive">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              {t('monthly_employee.not_confirmable', 'No es pot confirmar el registre encara')}
            </p>
            <ul className="list-disc space-y-0.5 pl-5 text-xs text-destructive/90">
              {validation.blockers.map((issue, i) => (
                <li key={`${issue.code}-${i}`}>{formatMonthlyCloseIssue(issue, t)}</li>
              ))}
            </ul>
          </div>
        ) : null}

        {confirmable ? (
          <div className="flex items-start gap-2 rounded-lg border bg-muted/30 p-3">
            <Checkbox
              id="ack-monthly-reviewed"
              checked={ackReviewed}
              onCheckedChange={(v) => setAckReviewed(v === true)}
            />
            <Label htmlFor="ack-monthly-reviewed" className="text-xs leading-snug cursor-pointer">
              {monthlyConfirmAckText(exportData.summary, t)}
            </Label>
          </div>
        ) : null}

        <DialogFooter className="gap-2 sm:gap-0">
          <Button type="button" variant="outline" onClick={() => handleOpenChange(false)}>
            {t('monthly_close.cancel', 'Cancel·lar')}
          </Button>
          <Button type="button" disabled={!canSubmit} onClick={onConfirm}>
            {isPending ? <Loader2 className="mr-1.5 h-4 w-4 animate-spin" /> : null}
            {t('monthly_report.confirm', 'Confirmar el meu registre')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
