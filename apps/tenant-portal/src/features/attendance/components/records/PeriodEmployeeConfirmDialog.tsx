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
import { formatTimesheetMinutes } from '../../api/timesheetService'
import { formatMonthlyCloseIssue } from '../../api/monthlyCloseIssueLabels'
import { usePeriodEmployeeConfirmValidation } from '../../api/usePeriodEmployeeConfirmValidation'
import type { MonthlyReportSummary } from '../../api/monthlyReportService'
import {
  MonthlyEffectiveTimeSummary,
  monthlyConfirmAckText,
} from './MonthlyEffectiveTimeSummary'

interface PeriodEmployeeConfirmDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  employeeId: string
  periodFrom: string
  periodTo: string
  summary: MonthlyReportSummary
  isPending: boolean
  onConfirm: () => void
}

export function PeriodEmployeeConfirmDialog({
  open,
  onOpenChange,
  employeeId,
  periodFrom,
  periodTo,
  summary,
  isPending,
  onConfirm,
}: PeriodEmployeeConfirmDialogProps) {
  const { t } = useTranslation('attendance')
  const [ackReviewed, setAckReviewed] = useState(false)

  const { data: validation, isLoading: validationLoading } = usePeriodEmployeeConfirmValidation(
    employeeId,
    periodFrom,
    periodTo,
    open,
  )

  const confirmable = validation?.confirmable ?? false
  const canSubmit = ackReviewed && confirmable && !isPending && !validationLoading

  function handleOpenChange(next: boolean) {
    if (!next) setAckReviewed(false)
    onOpenChange(next)
  }

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>
            {t('period_confirm.modal_title', 'Confirmar el registre de la setmana')}
          </DialogTitle>
          <DialogDescription>
            {t('period_confirm.modal_desc', {
              from: periodFrom,
              to: periodTo,
              defaultValue:
                'Revisa el resum del període {{from}} — {{to}} abans de confirmar.',
            })}
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-3 rounded-lg bg-muted/40 p-3 text-sm sm:grid-cols-3">
          <div>
            <p className="text-xs text-muted-foreground">{t('monthly_report.worked', 'Treballat')}</p>
            <p className="font-semibold tabular-nums">
              {formatTimesheetMinutes(summary.worked_minutes)}
            </p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">{t('monthly_report.expected', 'Previst')}</p>
            <p className="font-semibold tabular-nums">
              {formatTimesheetMinutes(summary.expected_minutes)}
            </p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">{t('monthly_report.difference', 'Diferència')}</p>
            <p className="font-semibold tabular-nums">
              {formatTimesheetMinutes(summary.difference_minutes)}
            </p>
          </div>
        </div>

        <MonthlyEffectiveTimeSummary summary={summary} />

        {validationLoading ? (
          <div className="flex items-center gap-2 text-xs text-muted-foreground">
            <Loader2 className="h-3.5 w-3.5 animate-spin" />
            {t('period_confirm.loading', 'Comprovant si pots confirmar el període…')}
          </div>
        ) : null}

        {!validationLoading && validation && !confirmable && validation.blockers.length > 0 ? (
          <div className="space-y-1 rounded-lg border border-destructive/30 bg-destructive/5 p-3">
            <p className="flex items-center gap-1.5 text-xs font-semibold text-destructive">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              {t('period_confirm.not_confirmable', 'No es pot confirmar el període encara')}
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
              id="ack-period-reviewed"
              checked={ackReviewed}
              onCheckedChange={(v) => setAckReviewed(v === true)}
            />
            <Label htmlFor="ack-period-reviewed" className="text-xs leading-snug cursor-pointer">
              {monthlyConfirmAckText(summary, t)}
            </Label>
          </div>
        ) : null}

        <DialogFooter className="gap-2 sm:gap-0">
          <Button type="button" variant="outline" onClick={() => handleOpenChange(false)}>
            {t('monthly_close.cancel', 'Cancel·lar')}
          </Button>
          <Button type="button" disabled={!canSubmit} onClick={onConfirm}>
            {isPending ? <Loader2 className="mr-1.5 h-4 w-4 animate-spin" /> : null}
            {t('period_confirm.submit', 'Confirmar aquesta setmana')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
